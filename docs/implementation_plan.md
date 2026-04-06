# Oracle — Implementation Plan

## Context

The data layer (schemas, contexts, migrations, auth) is complete. The next step is building the agent infrastructure that makes Oracle functional: fetching Polymarket data, ingesting OSINT signals, and synthesizing briefs. Markets are the central entity — everything relates back to a market — so Polymarket data must come first.

**Key architectural decisions (from April 2 session) that shape Phases 2–3:**
- **Two-tier supervision** — static global agents (NewsAgent, EconomicAgent) under a `GlobalSupervisor`, and a flat `DynamicSupervisor` for all runtime-spawned agents parameterized by init args.
- **Dynamic agents are parameterized, not typed** — RedditAgent instances are scoped by category (`:finance`, `:politics`), CongressAgent/CLOBAgent by topic/market, SynthesisAgent by market. All live under one `DynamicSupervisor`.
- **Many-to-many signals** — `signals` table has no `market_id`. A `market_signals` join table holds `(market_id, signal_id, relevance_score)` since the same signal can be relevant to multiple markets with different scores.

**Supervision tree:**
```
Oracle.Supervisor (top-level, :one_for_one)
├── Oracle.Repo
├── Oracle.Cache (Redis)
├── Oracle.PubSub
│
├── Oracle.Agents.GlobalSupervisor (:one_for_one, static)
│   ├── NewsAgent
│   └── EconomicAgent
│
└── Oracle.Agents.DynamicSupervisor (DynamicSupervisor)
    ├── RedditAgent [category: :finance]
    ├── RedditAgent [category: :politics]
    ├── CongressAgent [topic_id: "abc"]
    ├── CLOBAgent [market_id: "abc"]
    └── SynthesisAgent [market_id: "abc"]
```

---

## Phase 1: Polymarket Data Layer -- COMPLETE

### 1.1 Fix Market schema — cast `end_date` -- DONE

- Added `:end_date` to `cast/3` in `market.ex` and to `on_conflict` replace list in `markets.ex`

### 1.2 `Oracle.HTTP` — shared HTTP client -- DONE

- `oracle/lib/oracle/http.ex` — Req wrapper with exponential backoff retry (4 attempts, 1s/2s/4s)
- Pattern matches on status codes: 200-299 success, 429/5xx retry, 4xx fail
- Uses `Integer.pow/2` for backoff delay calculation

### 1.3 `Oracle.Markets.PolymarketClient` — API wrapper -- DONE

- `oracle/lib/oracle/markets/polymarket_client.ex`
- `list_active_markets/1` — hits Gamma API with `end_date_min` filter for recent markets
- `get_market/1` — fetches single market by condition_id
- `normalize/1` — maps camelCase API fields to snake_case schema attrs
- `parse_probability/1` — decodes `outcomePrices` JSON string, uses `Float.parse/1` (handles both `"0"` and `"0.73"`)
- `parse_end_date/1` — parses date-only strings via `Date.from_iso8601!/1` + `DateTime.new!/3`

### 1.4 `Oracle.Agents.PolymarketAgent` — singleton GenServer -- DONE

- `oracle/lib/oracle/agents/polymarket_agent.ex`
- Polls every 2 minutes, upserts markets, records probability history
- Error handling: logs failures, never crashes on transient HTTP errors

### 1.5 Wire into supervision tree -- DONE

- Added to `application.ex` via `maybe_children/0` helper
- Disabled in test env via `config :oracle, :start_polymarket_agent, false`

### 1.6 Tests -- TODO

- `test/oracle/markets/polymarket_client_test.exs` — test `normalize/1` with fixture JSON, edge cases
- `test/oracle/agents/polymarket_agent_test.exs` — test poll cycle creates markets + probability history

### Lessons learned
- `DateTime.from_iso8601!/1` doesn't exist (only `Date.from_iso8601!/1` does) — use `DateTime.from_iso8601/1` with pattern match or parse as Date and convert
- `String.to_float("0")` crashes — use `Float.parse/1` which handles integers too
- Module attributes use `@name value` not `@name = value`
- `Enum.map(list, &function/1)` is like JS `array.map(fn)`
- `[head | tail]` destructures lists like JS spread `[first, ...rest]`
- GenServer `handle_info` must return `{:noreply, state}`
- `send(self(), :poll)` for immediate first poll, `Process.send_after` for delayed

---

## Phase 2: Engine + Agent Scaffolding

### 2.1 Behaviour modules -- DONE

**New file:** `oracle/lib/oracle/engine/polling_agent.ex`
- Callbacks: `fetch/1`, `relevance_context/1`, `poll_interval/0`
- `fetch/1` receives agent state, returns `{:ok, [raw_signal]}` or `{:error, reason}`
- `relevance_context/1` returns text to embed for each raw signal (some agents may want title+content, others just content)

**New file:** `oracle/lib/oracle/engine/synthesis_agent.ex`
- Callbacks: `build_prompt/2`, `parse_response/1`, `synthesis_threshold/0`

### 2.2 `Oracle.Agents.Base` macro -- DONE

**New file:** `oracle/lib/oracle/agents/base.ex`

`__using__` macro injects GenServer boilerplate shared by all polling agents (global and dynamic):
- `start_link/1`, `init/1`, `handle_info(:poll)`, `schedule_poll/1`
- `process_signals/2` — batch embed via `Oracle.Engine.Embeddings`, then **fan out** scoring against all active market question embeddings:
  1. Fetch all active market embeddings from DB (or a cached ETS/GenServer lookup)
  2. For each signal embedding, compute cosine similarity against every market's `question_embedding`
  3. For each (signal, market) pair where `relevance_score > 0.40`, insert into `market_signals` join table
  4. Deduplicate signals by URL via `ON CONFLICT DO NOTHING` upsert
- `defoverridable init: 1` for agents that need custom state
- Init args are passed through — dynamic agents receive their params (e.g., `category: :finance`, `market_id: "abc"`) via `start_link/1`

### 2.3 `Oracle.Engine.Embeddings` — OpenAI integration -- DONE

**New file:** `oracle/lib/oracle/engine/embeddings.ex`

- `embed(text)` — single text embedding via OpenAI `text-embedding-3-small`
- `embed_batch(texts)` — batch embedding (up to ~20 texts per call)
- `cosine_similarity(vec_a, vec_b)` — pure math, dot product of normalized vectors
- `score_against_markets(signal_embeddings, market_embeddings)` — for each signal, compute similarity against all markets, return list of `{signal, market_id, score}` tuples above threshold

### 2.4 Supervision infrastructure -- DONE

**Two-tier design:** static `GlobalSupervisor` for always-on agents, flat `DynamicSupervisor` for all parameterized agents.

**File:** `oracle/lib/oracle/application.ex`
- Add `{Registry, keys: :unique, name: Oracle.AgentRegistry}` — unique key per agent instance (e.g., `{RedditAgent, :finance}`, `{SynthesisAgent, market_id}`)
- Add `Oracle.Agents.GlobalSupervisor` — static supervisor for NewsAgent, EconomicAgent
- Add `{DynamicSupervisor, name: Oracle.Agents.DynamicSupervisor, strategy: :one_for_one}` — all runtime-spawned agents
- Keep PolymarketAgent as-is (singleton, statically supervised)

**New file:** `oracle/lib/oracle/agents/global_supervisor.ex`
- `Supervisor` with `:one_for_one` strategy
- Static children: `NewsAgent`, `EconomicAgent`
- These run unconditionally on app start

**New file:** `oracle/lib/oracle/agents/dynamic_agents.ex`
- Convenience module wrapping `Oracle.Agents.DynamicSupervisor` for spawning/stopping dynamic agents:
  - `start_agent(module, opts)` — e.g., `start_agent(RedditAgent, category: :finance)`
  - `stop_agent(module, key)` — e.g., `stop_agent(SynthesisAgent, market_id)`
  - `agent_running?(module, key)` — checks `Oracle.AgentRegistry`
- All dynamic agents register via `{:via, Registry, {Oracle.AgentRegistry, {module, key}}}`

### 2.5 Connect subscriptions to agent lifecycle -- DONE

**File:** `oracle/lib/oracle/markets/markets.ex`
- `subscribe/2` — after inserting subscription, call `ensure_question_embedding/1`, then spawn dynamic agents for this market if not already running:
  - `SynthesisAgent` with `market_id`
  - Potentially `CLOBAgent` with `market_id` (Polymarket order book monitoring)
  - Determine which `RedditAgent` categories are relevant (or start defaults if none running)
- `unsubscribe/2` — after deleting subscription, stop per-market agents (Synthesis, CLOB) if no subscribers remain. RedditAgent categories may stay alive if other markets still benefit.
- Add `subscriber_count/1` and `ensure_question_embedding/1` helpers
- `active_market_embeddings/0` — returns `[{market_id, question_embedding}]` for all markets with active subscriptions (used by all source agents for fan-out scoring)

### 2.6 Signal schema + migration for join table -- DONE

**Migration:** Create `market_signals` join table
```sql
CREATE TABLE market_signals (
  market_id BIGINT REFERENCES markets(id) ON DELETE CASCADE,
  signal_id BIGINT REFERENCES signals(id) ON DELETE CASCADE,
  relevance_score FLOAT NOT NULL,
  PRIMARY KEY (market_id, signal_id)
);
CREATE INDEX market_signals_market_score ON market_signals(market_id, relevance_score);
```

**Migration:** Remove `market_id` and `relevance_score` from `signals` table (they move to the join table)

**New file:** `oracle/lib/oracle/signals/market_signal.ex`
- Schema for join table: `belongs_to :market`, `belongs_to :signal`, `field :relevance_score`

**File:** `oracle/lib/oracle/signals/signal.ex`
- Remove `belongs_to :market` and `field :relevance_score`
- Add `many_to_many :markets, through: [:market_signals, :market]`
- Add `:x` to source enum values
- Add unique index on `source_url` for upsert deduplication

**File:** `oracle/lib/oracle/signals/signals.ex`
- Update insert logic to use two-step: insert signal (upsert by URL), then insert market_signal rows
- Update queries (e.g., `top_for_market/2`) to join through `market_signals`

---

## Phase 3: Signal Agents + Synthesis

### 3.1 NewsAgent — RSS feeds (global, static)

**New file:** `oracle/lib/oracle/agents/news_agent.ex`
- Feeds: AP News, BBC World, NPR
- 5-min poll interval
- Parse RSS XML with Erlang `:xmerl` (no new dep needed)
- Deduplicate by URL in agent state (`seen_urls` MapSet)
- On each poll: fetch → embed new signals → fan-out score against all active markets → insert signal + market_signal rows
- Requires `Oracle.HTTP` to support raw (non-JSON) responses — add `get_raw/2`

### 3.2 RedditAgent — OAuth + subreddits (dynamic, by category)

**New file:** `oracle/lib/oracle/agents/reddit_agent.ex`
**New file:** `oracle/lib/oracle/agents/reddit_auth.ex`
- **Dynamic** — each instance is parameterized by a `category` (e.g., `:finance`, `:politics`, `:science`, `:crypto`)
- Each category maps to a set of subreddits (e.g., `:politics` → `[r/politics, r/worldnews, r/geopolitics]`)
- Spawned under `Oracle.Agents.DynamicSupervisor` via `DynamicAgents.start_agent(RedditAgent, category: :finance)`
- Registered via `{:via, Registry, {Oracle.AgentRegistry, {RedditAgent, category}}}`
- OAuth 2.0 client credentials flow — shared via `RedditAuth` GenServer (singleton, manages token refresh)
- 10-min poll interval
- Fan-out scoring against all active markets, same as global agents
- Category selection: when a market is subscribed, determine which Reddit categories are relevant (can be manual/config initially, ML-driven later)
- **TODO:** Smart category selection — embed subreddit descriptions, cosine similarity against market question to decide which categories to spawn instead of hardcoded defaults

### 3.3 EconomicAgent — FRED API (global, static)

**New file:** `oracle/lib/oracle/agents/economic_agent.ex`
- Series: FEDFUNDS, CPIAUCSL, UNRATE, GDP, DGS10, DEXUSEU
- 1-hour poll interval
- Change detection: only emit signal when value differs from last poll
- Overrides `handle_info(:poll)` to access `last_values` in state
- Economic signals are likely relevant to fewer markets — fan-out scoring naturally handles this

### 3.4 CongressAgent — Congress.gov API (dynamic, by topic) — STRETCH

**New file:** `oracle/lib/oracle/agents/congress_agent.ex`
- **Dynamic** — parameterized by topic/search query (e.g., legislation keywords relevant to a market)
- Tracks bills, votes, committee actions via Congress.gov API (free, no auth)
- Spawned per market or per topic cluster
- Registered via `{:via, Registry, {Oracle.AgentRegistry, {CongressAgent, topic_id}}}`
- 30-min poll interval (Congress data doesn't move fast)
- High-value for political prediction markets — covers legislation, confirmations, executive orders

### 3.5 CLOBAgent — Polymarket order book (dynamic, by market) — STRETCH

**New file:** `oracle/lib/oracle/agents/clob_agent.ex`
- **Dynamic** — one per subscribed market, monitors Polymarket CLOB API for that market
- Detects abnormal volume spikes or rapid probability shifts as early warning signals
- Spawned alongside SynthesisAgent on market subscription
- 5-min poll interval
- Signals from this agent are already market-specific — no fan-out needed, direct insert to `market_signals`

### 3.6 SynthesisAgent — LLM briefs (dynamic, per market)

**New file:** `oracle/lib/oracle/agents/synthesis_agent.ex`
- Spawned per market under `Oracle.Agents.DynamicSupervisor`
- Timer-based (30-min check interval) with threshold gate (5+ new signals since last brief)
- Queries top signals via `Oracle.Signals.top_for_market/2` (joins through `market_signals`)
- Builds prompt with market context + ranked signals
- Calls OpenAI via `Oracle.Engine.LLM.complete/2`
- Writes brief via `Oracle.Briefs.insert/1`
- Broadcasts `{:new_brief, brief}` via PubSub
- Tracks `last_brief_generated_at` in GenServer state, enforces 10-min cooldown
- Registered via `{:via, Registry, {Oracle.AgentRegistry, {SynthesisAgent, market_id}}}`

### 3.7 Agent garbage collection

- On unsubscribe (or periodically), check which dynamic RedditAgent categories are still needed by at least one active market subscription
- Stop orphaned RedditAgents that no longer serve any subscribed market
- `stop_market_agents/1` currently only stops SynthesisAgent (per-market) — RedditAgents are shared and need this sweep to clean up
- Could run as a periodic task or be triggered on every unsubscribe after the subscriber count check

### 3.8 LLM module

**New file:** `oracle/lib/oracle/engine/llm.ex`
- `complete(prompt, opts)` — OpenAI chat completions (`gpt-4o-mini`)
- Requires `Oracle.HTTP.post/3` (add to HTTP module)

### 3.8 HTTP module extensions

**File:** `oracle/lib/oracle/http.ex`
- Add `post(url, body, opts)` — for OpenAI API calls
- Add `get_raw(url, opts)` — returns raw body string for RSS XML

---

## Build order within phases

```
Phase 1: Market schema fix -> Oracle.HTTP -> PolymarketClient -> PolymarketAgent -> sup tree -> tests
Phase 2: Signal migration (join table) -> Behaviours -> Base macro (with fan-out) -> Embeddings -> GlobalSupervisor + DynamicSupervisor -> DynamicAgents module -> subscription lifecycle
Phase 3: NewsAgent (validate Base, global) -> RedditAuth + RedditAgent (validate dynamic spawning) -> EconomicAgent -> LLM module -> SynthesisAgent -> [stretch: CongressAgent, CLOBAgent]
```

## Verification

- **Phase 1:** `mix phx.server`, watch logs for Polymarket polling. Check `markets` and `probability_history` tables populate. Run `mix test`.
- **Phase 2:** Run migration, verify `market_signals` table exists. Check `Oracle.Agents.GlobalSupervisor` starts with static agents. Use `DynamicAgents.start_agent/2` in iex to spawn a test agent, verify it registers in `Oracle.AgentRegistry`. Stop it, verify cleanup.
- **Phase 3:** Subscribe to a market → verify SynthesisAgent + RedditAgent(s) spawn. Global agents (News, Economic) poll and fan-out score → `market_signals` rows appear. Check a signal relevant to multiple markets gets separate `market_signals` entries. Wait for synthesis threshold → brief generated and PubSub broadcast received. Unsubscribe → per-market agents terminate.
