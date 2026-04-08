# Semantic Prediction Market Intelligence Platform

## Summary

A distributed system that continuously ingests data from multiple prediction market APIs (Polymarket, Metaculus, Manifold) and OSINT sources (Reddit, GDelt/NewsAPI), enriches each market with semantic context, and enables natural language querying across markets using a RAG (Retrieval Augmented Generation) pipeline. The system surfaces cross-platform insights, historical base rates, and sentiment-vs-probability correlations that no single prediction market platform provides natively.

---

## Motivation

Prediction markets are an underutilized source of crowd intelligence. Platforms like Polymarket are optimized for trading, not analysis. A serious analyst following geopolitical or macroeconomic events must manually browse multiple platforms with no way to connect the dots semantically. This platform makes the aggregate signal legible.

---

## Core Features

- **Cross-platform semantic search** — query across Polymarket, Metaculus, and Manifold simultaneously using natural language, even when markets use different vocabulary
- **Historical base rate retrieval** — find resolved Metaculus questions semantically similar to an active market and surface their outcomes as probabilistic context
- **OSINT sentiment correlation** — track Reddit and news sentiment alongside market probabilities over time to detect lead/lag relationships
- **Cross-source discrepancy detection** — flag markets where Metaculus forecasters and Polymarket traders diverge significantly
- **LLM-generated briefings** — ask questions like *"what do markets think about AI regulation in 2026?"* and get a grounded, cited summary

---

## Architecture

### Data Pipeline

```
Raw API Data → Normalize → Enrich → Embed → Store
```

| Layer | Description |
|---|---|
| **Ingest** | Concurrent Elixir GenServer pools, one per source, each with its own poll interval and rate limiter |
| **Normalize** | Maps all sources to a common market schema: `{id, source, question, probability, volume, closes_at, resolved, outcome}` |
| **Enrich** | Fetches related news and Wikipedia context for new/changed markets only |
| **Content hash check** | Skips re-embedding if market text hasn't meaningfully changed |
| **Embed** | OpenAI `text-embedding-3-small` for vector embeddings; LLM sentiment scoring for OSINT documents |
| **Store** | Postgres for relational data (high-write), pgvector for embeddings (low-write), sentiment time-series table |
| **Query** | RAG pipeline: semantic retrieval from pgvector → hydrate with Postgres rows → LLM response generation |

### Data Sources

| Source | Type | Poll Interval | Daily Writes |
|---|---|---|---|
| Polymarket | Prediction markets | 2 min | ~72,000 |
| Metaculus | Forecasting questions | 30 min | ~1,200 |
| Manifold Markets | Community markets | 15 min | ~2,400 |
| Reddit | OSINT sentiment | 10 min | ~200 |
| GDelt / NewsAPI | News sentiment | 15 min | ~500 |

### Throughput Estimates

- **~115,000 rows/day** written to Postgres
- **Peak ~2–3 writes/second** — well within single-instance Postgres capacity
- **~500 embedding API calls/day** (only on new/changed content)
- **~$0.15/day** estimated OpenAI API cost at light usage
- **~15 GB** estimated storage after one year

---

## Technology Stack

| Concern | Technology |
|---|---|
| Concurrent ingestion workers | Elixir (GenServers, Supervisors) |
| Job queue / backpressure | Broadway or Oban |
| Relational storage | PostgreSQL |
| Vector storage | pgvector (Postgres extension) |
| Embedding model | OpenAI `text-embedding-3-small` |
| LLM for RAG responses | OpenAI GPT-4o or Claude |
| API / query layer | Phoenix (Elixir) or FastAPI (Python) |

---

## Database Design (High Level)

- **`markets`** — normalized market records from all sources; updated on every poll
- **`market_embeddings`** — vector embeddings of enriched market text; updated only on content change
- **`sentiment_scores`** — time-series of LLM-generated sentiment scores per market per OSINT source
- **`osint_documents`** — raw Reddit posts and news articles linked to relevant markets
- **`price_history`** — probability snapshots over time per market for trend analysis

---

## Interesting Engineering Problems

- **Per-source rate limiting** — each Elixir worker independently manages a token bucket to respect API limits (Reddit: 100 req/min) without affecting other workers
- **Idempotent ingestion** — content hash comparison ensures markets are only re-embedded when their text actually changes, not on every probability update
- **Embedding batching** — OSINT documents are batched into bulk embedding API calls rather than embedded one-by-one, reducing latency from minutes to seconds
- **Fault isolation** — Elixir's supervisor tree ensures a crashed worker (e.g. GDelt goes down) does not affect the rest of the pipeline
- **Semantic deduplication** — near-duplicate market questions across platforms are detected via cosine similarity threshold before storing

---

## Resume / Portfolio Value

- Demonstrates distributed systems design with Elixir concurrency primitives
- Integrates a production RAG pipeline with vector database
- Real-world data from live APIs with meaningful domain application
- Addresses rate limiting, fault tolerance, idempotency, and schema normalization
- Novel research angle: sentiment-vs-probability correlation over time

---

## Project Requirements Checklist

- [x] Reads and writes to persistent data
- [x] Stateful system with continuous data ingestion
- [x] Concurrency (Elixir supervisor tree of workers)
- [x] Security considerations (API key management, no public data exposure)
- [x] Interesting domain (prediction markets + OSINT)
- [x] Resume/portfolio worthy
- [x] 30–40 hour scope (pipeline + storage + query layer + UI)
