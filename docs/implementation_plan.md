# Oracle — Implementation Plan

## Context

The data layer (schemas, contexts, migrations, auth) is complete. The next step is building the agent infrastructure that makes Oracle functional: fetching Polymarket data, spawning per-market agent swarms, ingesting OSINT signals, and synthesizing briefs. Markets are the central entity — everything `belongs_to :market` — so Polymarket data must come first.

---

## Phase 1: Polymarket Data Layer

### 1.1 Fix Market schema — cast `end_date`

**File:** `oracle/lib/oracle/markets/market.ex`
- Add `:end_date` to the `cast/3` list in `changeset/2`

**File:** `oracle/lib/oracle/markets/markets.ex`
- Add `:end_date` to the `on_conflict: {:replace, [...]}` list in `upsert/1`

### 1.2 `Oracle.HTTP` — shared HTTP client

**New file:** `oracle/lib/oracle/http.ex`

Thin wrapper around `Req` with exponential backoff retry. Plain module, not a GenServer.

- `get(url, opts \\ [])` — GET request, returns `{:ok, body}` (parsed JSON) or `{:error, reason}`
- Retry: up to 4 attempts, delays 1s/2s/4s. Retry on 429/5xx. Fail on 4xx.
- Opts: `:headers`, `:params` (query params)

### 1.3 `Oracle.Markets.PolymarketClient` — API wrapper

**New file:** `oracle/lib/oracle/markets/polymarket_client.ex`

- `list_active_markets(opts \\ [])` — `GET https://gamma-api.polymarket.com/markets?active=true&limit=50`
- `get_market(condition_id)` — `GET https://gamma-api.polymarket.com/markets/{condition_id}`
- Internal `normalize/1` — maps Gamma API JSON to Market schema attrs:
  - `condition_id`, `question`, `active`, `end_date` (from `end_date_iso`)
  - `probability` parsed from `outcomePrices` (JSON string `"[\"0.73\",\"0.27\"]"` → take first float)

### 1.4 `Oracle.Agents.PolymarketAgent` — singleton GenServer

**New file:** `oracle/lib/oracle/agents/polymarket_agent.ex`

- Polls every 2 minutes via `Process.send_after`
- `handle_info(:poll)`:
  1. `PolymarketClient.list_active_markets()`
  2. For each market: `Oracle.Markets.upsert(attrs)`
  3. For each successful upsert: `Oracle.Markets.record_probability(market.id, probability)`
  4. Log errors, never crash on transient HTTP failures
- `init/1`: sends `:poll` immediately via `send(self(), :poll)`

### 1.5 Wire into supervision tree

**File:** `oracle/lib/oracle/application.ex`
- Add `Oracle.Agents.PolymarketAgent` after PubSub, before Endpoint
- Conditionally disable in test env

**File:** `oracle/config/test.exs`
- `config :oracle, :start_polymarket_agent, false`

### 1.6 Tests

- `test/oracle/markets/polymarket_client_test.exs` — test `normalize/1` with fixture JSON, edge cases
- `test/oracle/agents/polymarket_agent_test.exs` — test poll cycle creates markets + probability history

### Phase 1 files

| File | Action | Purpose |
|---|---|---|
| `lib/oracle/http.ex` | Create | Shared HTTP + retry |
| `lib/oracle/markets/polymarket_client.ex` | Create | Gamma API wrapper |
| `lib/oracle/agents/polymarket_agent.ex` | Create | Singleton polling GenServer |
| `lib/oracle/markets/market.ex` | Edit | Add `:end_date` to cast |
| `lib/oracle/markets/markets.ex` | Edit | Add `:end_date` to on_conflict |
| `lib/oracle/application.ex` | Edit | Add agent to sup tree |
| `config/test.exs` | Edit | Disable agent in test |

---

## Phase 2: Engine + Agent Scaffolding

### 2.1 Behaviour modules

**New file:** `oracle/lib/oracle/engine/polling_agent.ex`
- Callbacks: `fetch/1`, `relevance_context/1`, `poll_interval/0`
- `topic` type maps to Market struct fields (id, question, question_embedding)

**New file:** `oracle/lib/oracle/engine/synthesis_agent.ex`
- Callbacks: `build_prompt/2`, `parse_response/1`, `synthesis_threshold/0`

### 2.2 `Oracle.Agents.Base` macro

**New file:** `oracle/lib/oracle/agents/base.ex`

`__using__` macro injects GenServer boilerplate following the updated flow (no Broadway):
- `start_link/1`, `init/1`, `handle_info(:poll)`, `schedule_poll/1`
- `process_signals/2` — calls `Oracle.Engine.Embeddings.score_signals/2`, filters by 0.40 threshold, writes via `Oracle.Signals.insert/1`
- `defoverridable init: 1` for agents that need custom state (RedditAgent, EconomicAgent)

### 2.3 `Oracle.Engine.Embeddings` — OpenAI integration

**New file:** `oracle/lib/oracle/engine/embeddings.ex`

- `embed(text)` — single text embedding via OpenAI `text-embedding-3-small`
- `embed_batch(texts)` — batch embedding (up to ~20 texts per call)
- `cosine_similarity(vec_a, vec_b)` — pure math
- `score_signals(raw_signals, market_embedding)` — batch embed, compute similarity, return enriched signals

### 2.4 Supervision infrastructure

**New file:** `oracle/lib/oracle/markets/room_supervisor.ex`
- `DynamicSupervisor` — `start_room/1`, `stop_room/1`, `room_running?/1`
- Uses `Oracle.MarketRegistry` for room PID lookup

**New file:** `oracle/lib/oracle/market_room/supervisor.ex`
- Per-market `Supervisor` (`:one_for_one`, `max_restarts: 3, max_seconds: 5`)
- Starts: NewsAgent, RedditAgent, EconomicAgent, XAgent, SynthesisAgent
- Registers via `{:via, Registry, {Oracle.MarketRegistry, market_id}}`

**File:** `oracle/lib/oracle/application.ex`
- Add `{Registry, keys: :unique, name: Oracle.MarketRegistry}`
- Add `Oracle.Markets.RoomSupervisor`

### 2.5 Connect subscriptions to room lifecycle

**File:** `oracle/lib/oracle/markets/markets.ex`
- `subscribe/2` — after inserting subscription, start room if not running (calls `ensure_question_embedding/1` first)
- `unsubscribe/2` — after deleting subscription, stop room if no subscribers remain
- Add `subscriber_count/1` and `ensure_question_embedding/1` helpers

### 2.6 Signal schema update

**File:** `oracle/lib/oracle/signals/signal.ex`
- Add `:x` to source enum values (no migration needed, Ecto.Enum is app-level)

---

## Phase 3: Signal Agents + Synthesis

### 3.1 NewsAgent — RSS feeds

**New file:** `oracle/lib/oracle/agents/news_agent.ex`
- Feeds: AP News, BBC World, NPR
- 5-min poll interval
- Parse RSS XML with Erlang `:xmerl` (no new dep needed)
- Deduplicate by URL in agent state (`seen_urls` MapSet)
- Requires `Oracle.HTTP` to support raw (non-JSON) responses — add `get_raw/2`

### 3.2 RedditAgent — OAuth + subreddits

**New file:** `oracle/lib/oracle/agents/reddit_agent.ex`
**New file:** `oracle/lib/oracle/agents/reddit_auth.ex`
- OAuth 2.0 client credentials flow, token stored in GenServer state
- Token refresh when within 5 min of expiry
- Search relevant subreddits with market keywords
- 10-min poll interval

### 3.3 EconomicAgent — FRED API

**New file:** `oracle/lib/oracle/agents/economic_agent.ex`
- Series: FEDFUNDS, CPIAUCSL, UNRATE, GDP, DGS10, DEXUSEU
- 1-hour poll interval
- Change detection: only emit signal when value differs from last poll
- Overrides `handle_info(:poll)` to access `last_values` in state

### 3.4 XAgent — mock

**New file:** `oracle/lib/oracle/agents/x_agent.ex`
- Generates 1-3 synthetic signals per poll using market question keywords
- 15-min poll interval
- Simplest agent — good for validating the Base macro end-to-end

### 3.5 SynthesisAgent — LLM briefs

**New file:** `oracle/lib/oracle/agents/synthesis_agent.ex`
- Timer-based (30-min check interval) with threshold gate (5+ new signals)
- Queries top signals via `Oracle.Signals.top_for_market/2`
- Builds prompt with market context + ranked signals
- Calls OpenAI via `Oracle.Engine.LLM.complete/2`
- Writes brief via `Oracle.Briefs.insert/1`
- Broadcasts `{:new_brief, brief}` via PubSub

**New file:** `oracle/lib/oracle/engine/llm.ex`
- `complete(prompt, opts)` — OpenAI chat completions (`gpt-4o-mini`)
- Requires `Oracle.HTTP.post/3` (add to HTTP module)

### 3.6 HTTP module extensions

**File:** `oracle/lib/oracle/http.ex`
- Add `post(url, body, opts)` — for OpenAI API calls
- Add `get_raw(url, opts)` — returns raw body string for RSS XML

---

## Build order within phases

```
Phase 1: Market schema fix -> Oracle.HTTP -> PolymarketClient -> PolymarketAgent -> sup tree -> tests
Phase 2: Behaviours -> Base macro -> Embeddings -> RoomSupervisor -> MarketRoom.Supervisor -> subscription lifecycle
Phase 3: XAgent (validate Base) -> NewsAgent -> RedditAgent -> EconomicAgent -> LLM module -> SynthesisAgent
```

## Verification

- **Phase 1:** `mix phx.server`, watch logs for Polymarket polling. Check `markets` and `probability_history` tables populate. Run `mix test`.
- **Phase 2:** Subscribe a user to a market in iex, verify room starts (`Registry.lookup`). Unsubscribe, verify room stops.
- **Phase 3:** Start a market room, verify agents poll and signals appear in DB. Wait for synthesis threshold, verify brief generated.
