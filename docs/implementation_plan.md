# Oracle — Implementation Plan

## Context

The data layer (schemas, contexts, migrations, auth) is complete. The next step is building the agent infrastructure that makes Oracle functional: fetching Polymarket data, ingesting OSINT signals, and synthesizing briefs. Markets are the central entity — everything relates back to a market — so Polymarket data must come first.

**Key architectural decisions (from April 2 session) that shape Phases 2–3:**
- **Two-tier supervision** — static global agents under a `GlobalSupervisor`, and a flat `DynamicSupervisor` for all runtime-spawned agents parameterized by init args.
- **Three tiers of agents:** global static (EconomicAgent, NewsAgent RSS fallback, PolymarketAgent), dynamic by category (GdeltAgent, RedditAgent), dynamic per market (SynthesisAgent).
- **Dynamic agents are parameterized, not typed** — GdeltAgent/RedditAgent instances are scoped by category (`:finance`, `:politics`), CongressAgent/CLOBAgent by topic/market, SynthesisAgent by market. All live under one `DynamicSupervisor`.
- **Many-to-many signals** — `signals` table has no `market_id`. A `market_signals` join table holds `(market_id, signal_id, relevance_score)` since the same signal can be relevant to multiple markets with different scores.

**Supervision tree:**
```
Oracle.Supervisor (top-level, :one_for_one)
├── Oracle.Repo
├── Oracle.Cache (Redis)
├── Oracle.PubSub
│
├── Oracle.Agents.GlobalSupervisor (:one_for_one, static)
│   ├── PolymarketAgent              market metadata + probability sync, 2 min
│   ├── NewsAgent                    RSS fallback (AP, BBC, NPR), 5 min
│   └── EconomicAgent               FRED API, 1 hr
│
└── Oracle.Agents.DynamicSupervisor (DynamicSupervisor)
    ├── GdeltAgent [category: :finance]      GDELT keyword search, 15 min
    ├── GdeltAgent [category: :politics]
    ├── RedditAgent [category: :finance]     Reddit OAuth, 10 min
    ├── RedditAgent [category: :politics]
    ├── SynthesisAgent [market_id: "abc"]    per-market, 30 min timer + threshold
    ├── CongressAgent [topic_id: "abc"]      stretch
    └── CLOBAgent [market_id: "abc"]         stretch
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

**File:** `oracle/lib/oracle/agents/base.ex`

`__using__` macro injects GenServer boilerplate shared by all polling agents (global and dynamic):
- `start_link/1`, `init/1`, `handle_info(:poll)`, `schedule_poll/1`
- `process_signals/1` — implemented:
  1. Short-circuits on empty signal list
  2. Batch embeds signals in chunks of 100 via `Embeddings.embed_batch/1`
  3. Loads active market embeddings via `Markets.active_market_embeddings/0`
  4. For each signal, scores against all markets via `Embeddings.cosine_similarity/2`
  5. For pairs where `relevance_score > 0.40`, inserts signal + market_signal rows via `Signals.insert/2`
  6. Only inserts signals relevant to at least one market
- `defoverridable start_link: 1, init: 1` for agents that need custom state or Registry registration
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
- `subscribe/2` — after inserting subscription, call `ensure_question_embedding/1`, then spawn dynamic agents:
  - `SynthesisAgent` with `market_id`
  - `GdeltAgent` with category (auto-classified via `Oracle.Engine.Categories.classify/1`)
  - TODO: `RedditAgent` with category (same classification)
- `unsubscribe/2` — after deleting subscription, stop per-market agents if no subscribers remain
  - TODO: stop category agents (GdeltAgent, RedditAgent) when no markets in that category remain
- Add `subscriber_count/1` and `ensure_question_embedding/1` helpers
- `active_market_embeddings/0` — returns markets with active subscriptions and embeddings (used by all source agents for fan-out scoring)

### 2.6 `Oracle.Engine.Categories` — market classification -- DONE

**New file:** `oracle/lib/oracle/engine/categories.ex`
- Pre-embedded category labels stored in `categories` table (name + 1536-dim embedding)
- `seed/0` — embeds category names via OpenAI, inserts into DB (idempotent, skips existing)
- `classify/1` — takes a market's `question_embedding`, scores against all category embeddings via cosine similarity, returns best match as atom (e.g. `:finance`)
- `all/0` — loads categories from DB with ETS read-through cache (lazy init, `:categories_cache` table)
- `invalidate_cache/0` — clears ETS for reloading after changes
- Categories: `finance`, `politics`, `crypto`, `sports`, `science`, `tech`
- Each agent maps categories to source-specific queries internally (e.g. GdeltAgent's `query_for_category/1`, RedditAgent's subreddit lists)

**New file:** `oracle/lib/oracle/categories/category.ex` — Ecto schema
**Migration:** `create_categories` — name (unique), embedding (vector 1536)
**Seeds:** `priv/repo/seeds.exs` calls `Categories.seed/0`

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

### 3.1a GdeltAgent — GDELT news (dynamic, by category) — DONE

**File:** `oracle/lib/oracle/agents/gdelt_agent.ex`
- **Dynamic** — each instance parameterized by category (`:finance`, `:politics`, `:science`, etc.)
- Queries GDELT DOC 2.0 API (`artlist` mode, JSON format, 250 max records, 60-min timespan)
- Overrides `start_link/1` for Registry name registration
- `fetch/1` pattern matches category from state, builds query via `query_for_category/1`
- `relevance_context/1` returns `signal.title` (GDELT doesn't provide full article text)
- `parse_response/1` maps GDELT articles to signal maps (source: `:news`, URL, title)
- 15-min poll interval
- Registered via `{:via, Registry, {Oracle.AgentRegistry, {GdeltAgent, category}}}`
- Free, no API key required
- **Note:** GDELT rate-limits aggressively (429s on back-to-back calls). Production polling interval is fine; testing in IEx needs spacing between calls.

### 3.1b NewsAgent — RSS feeds (global, static) — FALLBACK

**New file:** `oracle/lib/oracle/agents/news_agent.ex`
- Fallback if GDELT proves unreliable or insufficient
- Feeds: AP News, BBC World, NPR
- 5-min poll interval
- Parse RSS XML with Erlang `:xmerl` (no new dep needed)
- Global static agent — fetches all feeds, fan-out scores against all active markets
- Deduplicate by URL in agent state (`seen_urls` MapSet)
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
Phase 2: Signal migration (join table) -> Behaviours -> Base macro (with fan-out) -> Embeddings -> GlobalSupervisor + DynamicSupervisor -> DynamicAgents module -> subscription lifecycle -> Categories module
Phase 3: GdeltAgent ✓ -> RedditAuth + RedditAgent -> EconomicAgent -> LLM module -> SynthesisAgent -> [fallback: NewsAgent RSS] -> [stretch: CongressAgent, CLOBAgent]
```

## Next steps

1. **RedditAgent** — next dynamic agent. Same pattern as GdeltAgent: `use Oracle.Agents.Base`, override `start_link/1` for Registry, implement `fetch/1` with Reddit OAuth. Need `RedditAuth` GenServer for token management. Map categories to subreddit lists internally.
2. **Add `query_for_category` clauses** — GdeltAgent only handles `:finance` and `:politics`. Need catch-all or clauses for `:crypto`, `:sports`, `:science`, `:tech`.
3. **Category agent cleanup on unsubscribe** — `stop_market_agents/1` only stops SynthesisAgent. Need to check if any other markets in the same category still have subscribers before stopping GdeltAgent/RedditAgent.
4. **EconomicAgent** — global static agent, FRED API. Change detection pattern (only emit when value changes).
5. **SynthesisAgent** — per-market, timer + threshold gate, LLM prompt building, brief generation.
6. **Tests** — agent tests with mocked HTTP, categories classification tests.

## Verification

- **Phase 1:** `mix phx.server`, watch logs for Polymarket polling. Check `markets` and `probability_history` tables populate. Run `mix test`.
- **Phase 2:** Run migration, verify `market_signals` table exists. Check `Oracle.Agents.GlobalSupervisor` starts with static agents. Use `DynamicAgents.start_agent/2` in iex to spawn a test agent, verify it registers in `Oracle.AgentRegistry`. Stop it, verify cleanup.
- **Phase 3:** Subscribe to a market → verify SynthesisAgent + category agents (Gdelt, Reddit) spawn. Agents poll and fan-out score → `market_signals` rows appear. Check a signal relevant to multiple markets gets separate `market_signals` entries. Wait for synthesis threshold → brief generated and PubSub broadcast received. Unsubscribe → per-market agents terminate; category agents remain if other markets in that category are still subscribed.

---

## Appendix A: Per-Source Agent Reference

### GDELT DOC API

- **Endpoint:** `https://api.gdeltproject.org/api/v2/doc/doc?query=KEYWORDS&mode=ArtList&format=json`
- **Auth:** None required (free, public)
- **Rate limit:** Not formally published — use conservative polling (15 min) and respect HTTP 429
- **Returns:** JSON array of articles with title, URL, source, language, tone score, date
- **Category → keyword mapping:** Each category (`:finance`, `:politics`, etc.) maps to a set of GDELT search terms

### Reddit OAuth

- **Auth:** OAuth 2.0 client credentials flow (no user login for read-only)
- **Token endpoint:** `POST https://www.reddit.com/api/v1/access_token` with Basic auth (client_id:client_secret)
- **Tokens expire after 1 hour** — `RedditAuth` GenServer manages refresh
- **Rate limit:** 100 QPM (free tier, non-commercial)
- **Key endpoints:**
  - `GET /r/{subreddit}/new.json?limit=25`
  - `GET /r/{subreddit}/search.json?q={keyword}&sort=new&limit=25&t=day`
- **Category → subreddit mapping:**
  - `:finance` → `[r/investing, r/economics, r/wallstreetbets, r/stocks]`
  - `:politics` → `[r/worldnews, r/geopolitics, r/politics]`
  - `:science` → `[r/science, r/technology, r/MachineLearning]`

### FRED API

- **Endpoint:** `GET https://api.stlouisfed.org/fred/series/observations?series_id={ID}&api_key={KEY}&sort_order=desc&limit=1&file_type=json`
- **Auth:** API key (free at fred.stlouisfed.org)
- **Rate limit:** 120 requests/minute
- **Series monitored:** FEDFUNDS, CPIAUCSL, UNRATE, GDP, DGS10, DEXUSEU
- **Change detection:** Only emit signal when value differs from last poll

### RSS Feeds (NewsAgent fallback)

- AP News: `https://feeds.apnews.com/rss/apf-topnews`
- BBC News: `http://feeds.bbci.co.uk/news/rss.xml`
- NPR News: `https://feeds.npr.org/1001/rss.xml`
- Parse with Erlang `:xmerl` (no extra dep)
- Note: FT and Bloomberg feeds are paywalled/deprecated — avoid

---

## Appendix B: Error Handling Reference

### HTTP retry strategy

| Attempt | Delay | Condition |
|---|---|---|
| 1 | immediate | — |
| 2 | 1s | 429, 5xx, or network error |
| 3 | 2s | same |
| 4 | 4s | give up after |

Non-retryable: 400, 401, 403, 404 — log and skip.

### Error surface summary

| Failure type | Where caught | Action |
|---|---|---|
| HTTP timeout / 5xx | `Oracle.HTTP` retry wrapper | Exponential backoff, up to 4 attempts |
| HTTP 429 rate limit | `Oracle.HTTP` retry wrapper | Backoff + retry |
| HTTP 401/403 auth failure | Agent `fetch/1` | `{:error, :auth_failure}` — log, skip poll |
| Malformed API response | Agent `fetch/1` | Log + return `{:ok, []}` (empty, no crash) |
| Agent crash (unexpected) | Supervisor | Restart up to 3× in 5s |
| Repeated agent crashes | Supervisor | Supervisor terminates, propagates upward |
| LLM API failure (synthesis) | `SynthesisAgent` | Retry once; if fails, skip this synthesis cycle |

---

## Appendix C: Context API Reference

### `Oracle.Markets`

| Function | Description |
|---|---|
| `upsert/1` | Insert or update market by `condition_id`. Replaces probability, active, updated_at on conflict. |
| `get_by_condition_id/1` | Fetch market by Polymarket ID. Returns `nil` if not found. |
| `set_question_embedding/2` | Update market's embedding. Uses `Ecto.Changeset.change` (skips validation). |
| `list_active/0` | All active markets, newest first. |
| `subscribe/2` | Create subscription row in `Ecto.Multi` transaction. |
| `unsubscribe/2` | Delete subscription. Returns `{:error, :not_found}` if not subscribed. |
| `list_markets_for_user/1` | Markets the user is subscribed to (inner join). |
| `active_market_embeddings/0` | Returns `[{market_id, question_embedding}]` for all markets with active subscriptions (used by agents for fan-out scoring). |
| `record_probability/2` | Bulk insert probability history via `Repo.insert_all`. |
| `probability_history_for/1` | All probability rows for a market, ascending by time. |

### `Oracle.Signals`

| Function | Description |
|---|---|
| `insert/1` | Validate and insert signal. Upsert by `source_url` to deduplicate. |
| `insert_market_signal/1` | Insert `market_signals` join row (signal_id, market_id, relevance_score). |
| `top_for_market/2` | Signals for market with score > 0.6, newest first (joins through `market_signals`). Default limit 30. |
| `count_since/2` | Count signals for market since datetime. Used by SynthesisAgent threshold gate. |

### `Oracle.Briefs`

| Function | Description |
|---|---|
| `insert/1` | Validate and insert brief. |
| `latest_for_market/1` | Most recent brief. Used by SynthesisAgent cooldown check. |
| `list_for_market/1` | All briefs for market, newest first. |

---

## Appendix D: Data Layer Notes

### Migrations

| Migration | Table | Notes |
|---|---|---|
| `create_users_auth_tables` | `users`, `users_tokens` | Generated by `phx.gen.auth` |
| `create_markets` | `markets` | Enables pgvector extension. Uses `up/down` (raw SQL can't auto-reverse). |
| `create_signals` | `signals` | Append-only (`updated_at` omitted). No `market_id` — association via `market_signals`. |
| `create_briefs` | `briefs` | Append-only (`updated_at` omitted) |
| `create_probability_history` | `probability_history` | No timestamps — just `recorded_at` |
| `create_user_subscriptions` | `user_subscriptions` | Composite unique index on `(user_id, market_id)` |
| `create_market_signals` | `market_signals` | Join table: `(market_id, signal_id, relevance_score)`. Index on `(market_id, relevance_score)`. |

### Key data layer decisions

- **`embedding` and `question_embedding` not in `cast`** — set programmatically, never from user input
- **`Repo.insert_all` for probability history** — bypasses changeset for high-frequency internal writes
- **`Ecto.Multi` for subscribe** — transaction allows adding agent lifecycle as a second step
- **IVFFlat index deferred** — added in separate migration once ~1000+ signals exist
- **All FKs use `on_delete: :delete_all`** — deleting a market cascades to signals, briefs, history, subscriptions
- **pgvector type registration** — `lib/oracle/postgrex_types.ex` + `config :oracle, Oracle.Repo, types: Oracle.PostgrexTypes`
