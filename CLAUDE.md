# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Oracle — an Elixir/Phoenix application that subscribes to Polymarket prediction markets, runs shared OSINT-ingesting agents (GDELT news, Reddit, FRED economic data), scores signals via embedding cosine similarity against all active markets, and synthesizes per-market AI intelligence briefs served through a Phoenix LiveView dashboard.

## Commands

```bash
# Setup (first time)
mix setup

# Start dev server
mix phx.server

# Run tests
mix test

# Run a single test file
mix test test/path/to/file_test.exs

# Run a single test by line number
mix test test/path/to/file_test.exs:42

# Database
mix ecto.migrate
mix ecto.reset   # drop, create, migrate, seed
```

**Required env vars** (copy `.env.example` → `.env`):
- `OPENAI_API_KEY` — embeddings (`text-embedding-3-small`) and LLM synthesis
- `REDDIT_CLIENT_ID` / `REDDIT_CLIENT_SECRET` — Reddit OAuth (client credentials)
- `FRED_API_KEY` — Federal Reserve economic data (free at fred.stlouisfed.org)

**Prerequisites:** Elixir 1.17+, Postgres 16+ with pgvector extension, Redis.

## Architecture

### Two-layer design

**Engine** (`Oracle.Engine`) — source-agnostic. Defines behaviour contracts (`PollingAgent`, `SynthesisAgent`), embedding/scoring logic, and supervision scaffolding. Has no knowledge of Polymarket or any specific data source.

**Vertical** (`Oracle.Agents.*`, `Oracle.Markets.*`) — concrete implementations. Each data source implements `Oracle.Engine.PollingAgent`; synthesis implements `Oracle.Engine.SynthesisAgent`.

### Supervision tree

```
Oracle.Supervisor (top-level, :one_for_one)
├── Oracle.Repo                              Ecto/Postgres
├── Oracle.Cache                             Redis via Redix
├── Oracle.PubSub                            Phoenix.PubSub
│
├── Oracle.Agents.GlobalSupervisor           :one_for_one, static
│   ├── PolymarketAgent                      market metadata + probability sync, 2 min
│   ├── NewsAgent                            RSS fallback (AP, BBC, NPR), 5 min
│   └── EconomicAgent                        FRED API, 1 hr
│
└── Oracle.Agents.DynamicSupervisor          flat DynamicSupervisor
    ├── GdeltAgent [category: :finance]      GDELT keyword search, 15 min
    ├── GdeltAgent [category: :politics]
    ├── RedditAgent [category: :finance]     Reddit OAuth, 10 min
    ├── RedditAgent [category: :politics]
    ├── SynthesisAgent [market_id: "abc"]    per-market, 30 min timer + threshold
    ├── CongressAgent [topic_id: "abc"]      stretch goal
    └── CLOBAgent [market_id: "abc"]         stretch goal
```

**Three tiers of agents:**
- **Global static** (always running, fan-out score against all markets): EconomicAgent, NewsAgent (RSS fallback), PolymarketAgent
- **Dynamic by category** (shared across markets in same category): GdeltAgent, RedditAgent. Spawned when a market in that category is subscribed; stopped when no markets in that category remain.
- **Dynamic per market**: SynthesisAgent. Spawned on subscription, stopped when no subscribers remain.

All dynamic agents register via `{:via, Registry, {Oracle.AgentRegistry, {module, key}}}` and are managed through `Oracle.Agents.DynamicAgents`.

### Agent pattern

All polling agents `use Oracle.Agents.Base`, which provides GenServer boilerplate (`init`, `handle_info(:poll)`, `schedule_poll`) and the `process_signals/2` fan-out scoring logic. Concrete agents implement the three `PollingAgent` callbacks: `fetch/1`, `relevance_context/1`, `poll_interval/0`.

`PolymarketAgent` is not a signal source — it syncs market metadata and probability history directly to the DB, bypassing the signal flow.

### Signal flow (no Broadway)

Each agent handles the full signal lifecycle internally — no pipeline abstraction, no message queue:

1. Fetch raw signals from external source
2. Batch embed via OpenAI `text-embedding-3-small`
3. Fan-out: compute cosine similarity against every active market's `question_embedding`
4. For each (signal, market) pair where `relevance_score > 0.40`, insert into `market_signals` join table
5. Deduplicate signals by URL via `ON CONFLICT DO NOTHING` upsert

`SynthesisAgent` is timer-based (30-min interval) with a threshold gate (5+ new signals since last brief). Queries top signals via `market_signals` join, builds LLM prompt, writes brief, broadcasts via PubSub to LiveView.

### Data model

`markets` is the central entity:
- `signals` — every ingested OSINT signal with embedding vector (1536-dim). No market FK — market association is through the join table.
- `market_signals` — join table: `(market_id, signal_id, relevance_score)`. Same signal can score differently against different markets.
- `briefs` — LLM-generated intelligence briefs (JSONB `key_signals` field). Belongs to market.
- `probability_history` — time-series Polymarket probabilities for charting
- `user_subscriptions` — which users watch which markets, with `alert_threshold`

pgvector IVFFlat index on `signals.embedding` (deferred until sufficient data exists).

### Error handling philosophy

- **Let it crash** — OTP supervision handles restarts; agents crash rather than corrupt state.
- **Retry transient HTTP failures** — `Oracle.HTTP` uses Req with exponential backoff (4 attempts, 1s/2s/4s). Retries on 429/5xx; non-retryable on 4xx auth errors.
- **Discard malformed data** — unparseable signals return `{:ok, []}`, not a crash.
- Supervisor restart intensity: `max_restarts: 3, max_seconds: 5`.

### Key docs

- `docs/implementation_plan.md` — detailed build plan, per-agent specs, context API reference
- `docs/PROGRESS.md` — architectural decision log
- `docs/DATABASE.md` — Postgres/Supabase connection setup
- `oracle/AGENTS.md` — Phoenix/LiveView specific instructions
