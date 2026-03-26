# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Oracle — an Elixir/Phoenix application that subscribes to Polymarket prediction markets and spawns per-market OTP agent swarms that continuously ingest OSINT (news, Reddit, economic data, social media), score signals via embedding cosine similarity, and synthesize AI intelligence briefs served through a Phoenix LiveView dashboard.

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

**Engine** (`Oracle.Engine`) — source-agnostic. Defines behaviour contracts, the Broadway ingest pipeline, embedding/scoring logic, and supervision scaffolding. Has no knowledge of Polymarket or any specific data source.

**Vertical** (`Oracle.Agents.*`, `Oracle.Markets.*`) — concrete implementations. Each data source implements `Oracle.Engine.PollingAgent`; synthesis implements `Oracle.Engine.SynthesisAgent`.

### Supervision tree

```
Oracle.Supervisor (one_for_one)
├── Oracle.Repo                        Ecto/Postgres
├── Oracle.Cache                       Redis via Redix
├── Oracle.PubSub                      Phoenix.PubSub
├── Oracle.Pipeline.Supervisor         Broadway ingest pipeline
└── Oracle.Markets.RoomSupervisor      DynamicSupervisor — spawned per user subscription
    └── Oracle.MarketRoom.Supervisor   one_for_one; agents are independent
        ├── NewsAgent                  RSS, 5 min poll
        ├── RedditAgent                OAuth, 10 min poll
        ├── EconomicAgent              FRED API, 1 hr poll
        ├── XAgent                     Mocked (Twitter API too expensive)
        └── SynthesisAgent             Event-driven (threshold of new signals)
```

`RoomSupervisor.start_room/1` is called when a user subscribes; `stop_room/1` when no subscribers remain.

### Agent pattern

All polling agents `use Oracle.Agents.Base`, which provides the GenServer boilerplate (init, `handle_info(:poll)`, `schedule_poll`). Concrete agents only implement the three `PollingAgent` callbacks: `fetch/1`, `relevance_context/1`, `poll_interval/0`.

`PolymarketAgent` is not a signal source — it syncs market metadata and probability history directly to the DB, bypassing the pipeline.

### Signal pipeline

Raw signals → Broadway pipeline → OpenAI embedding → cosine similarity vs. market question embedding → discard if `relevance_score < 0.40` → write to `signals` table. The market's `question_embedding` is pre-computed at subscription time and stored on the `markets` row.

`SynthesisAgent` is event-driven: when enough high-scoring signals accumulate (`synthesis_threshold`), it queries the top signals, calls the LLM via `build_prompt/2`, parses the response with `parse_response/1`, and writes a `briefs` row. Results broadcast via `Oracle.PubSub` to LiveView.

### Data model

`markets` is the central entity. Everything else has a `belongs_to :market`:
- `signals` — every ingested OSINT signal with embedding vector (1536-dim) + relevance score
- `briefs` — LLM-generated intelligence briefs (JSONB `key_signals` field)
- `probability_history` — time-series Polymarket probabilities for charting
- `user_subscriptions` — which users watch which markets, with `alert_threshold`

pgvector IVFFlat index on `signals.embedding` for similarity search.

### Error handling philosophy

- **Let it crash** — OTP supervision handles restarts; agents crash rather than corrupt state.
- **Retry transient HTTP failures** — `Oracle.HTTP.get_with_retry/3` does 4 attempts with exponential backoff (1s, 2s, 4s). Retries on 429/5xx; non-retryable on 4xx auth errors.
- **Discard malformed data** — unparseable signals return `{:ok, []}`, not a crash.
- **Broadway dead-lettering** — pipeline failures are logged and acknowledged (discarded) after 3 retries.
- Supervisor restart intensity: `max_restarts: 3, max_seconds: 5` on `MarketRoom.Supervisor`.

### Agents
Refer to /oracle/AGENTS.md for specific Phoenix/LiveView instructions
