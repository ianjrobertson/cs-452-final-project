# Oracle — Cost Analysis at Scale

This document models Oracle's operational costs and how they scale with signal volume and market count. The key architectural insight: **embedding costs scale with signal volume, not market count**, thanks to the global agent + fan-out scoring design.

---

## Assumptions

| Parameter | Value | Notes |
|---|---|---|
| Embedding model | `text-embedding-3-small` | 1536 dimensions |
| Embedding cost | $0.02 / 1M tokens | OpenAI pricing as of April 2026 |
| Avg tokens per signal | ~150 | Title + content snippet |
| LLM model (synthesis) | `gpt-4o-mini` | |
| LLM input cost | $0.15 / 1M tokens | |
| LLM output cost | $0.60 / 1M tokens | |
| Avg synthesis prompt | ~2,000 tokens in, ~800 tokens out | Market context + 20-30 signals |
| Synthesis interval | Every 30 min (if threshold met) | Max 48 briefs/market/day |
| Cosine similarity scoring | Free (CPU math) | Dot product of pre-computed vectors — no API call |

---

## Signal volume by source

| Source | Poll interval | Signals per poll | Signals/hour | Scaling behavior |
|---|---|---|---|---|
| NewsAgent (global) | 5 min | 5–15 | ~60–180 | Fixed — RSS feeds produce the same volume regardless of market count |
| RedditAgent (per category) | 10 min | 10–30 | ~60–180 per category | Linear with category count, NOT market count. Multiple markets can share a category. |
| EconomicAgent (global) | 1 hr | 6 (one per series) | ~6 | Fixed — FRED series don't change with market count |
| CongressAgent (per topic) | 30 min | 1–5 | ~2–10 per topic | Linear with topic count |
| CLOBAgent (per market) | 5 min | 0–1 (only on volume spikes) | ~0–12 | Linear with market count, but low volume |

---

## Cost 1: Embeddings

Embedding happens **once per signal**, regardless of how many markets exist. The fan-out scoring step (cosine similarity against each market's question embedding) is pure math on pre-computed vectors — zero API cost.

**Formula:**

```
Monthly embedding cost = (signals/hour) × 720 hours × 150 tokens × ($0.02 / 1,000,000)
```

| Scale | Active markets | Signal sources | Signals/hour | Monthly embedding cost |
|---|---|---|---|---|
| **Small** (demo) | 5 | News + 1 Reddit category + FRED | ~250 | **$0.54** |
| **Medium** (active user) | 25 | News + 3 Reddit categories + FRED + Congress | ~700 | **$1.51** |
| **Large** (production) | 100 | News + 8 Reddit categories + FRED + Congress | ~1,800 | **$3.89** |

### Architecture payoff: old vs. new design

The original per-market agent swarm would embed the same signal N times (once per market). The global agent design embeds once and fan-out scores with math.

| Scale | Markets | Old design (embed per market) | New design (embed once) | Savings |
|---|---|---|---|---|
| Small | 5 | $2.70 | $0.54 | 5x |
| Medium | 25 | $37.80 | $1.51 | 25x |
| Large | 100 | $389.00 | $3.89 | 100x |

Embedding cost savings scale linearly with market count. At 100 markets the old design would cost **100x more** for the same intelligence output.

---

## Cost 2: LLM Synthesis

Synthesis is inherently **per-market** — each market gets its own brief from its own signals. This is the cost that actually scales with market count.

**Formula:**

```
Monthly synthesis cost = markets × briefs/day × 30 days × ((2000 × $0.15 + 800 × $0.60) / 1,000,000)
```

Per brief: ~$0.00078 (input) + ~$0.00048 (output) = **~$0.0013 per brief**

| Scale | Active markets | Briefs/market/day | Briefs/month | Monthly LLM cost |
|---|---|---|---|---|
| **Small** | 5 | 6 | 900 | **$1.14** |
| **Medium** | 25 | 10 | 7,500 | **$9.45** |
| **Large** | 100 | 16 | 48,000 | **$60.48** |

Synthesis is the dominant cost at scale. Levers to control it:
- Increase synthesis interval (30 min → 1 hr cuts cost in half)
- Raise signal threshold (require more signals before triggering)
- Use a cheaper model for low-priority markets
- Batch multiple markets into a single LLM call (loses per-market prompt tailoring)

---

## Cost 3: External APIs

| API | Cost | Rate limits | Notes |
|---|---|---|---|
| Reddit (OAuth) | **Free** | 100 requests/min | Client credentials flow, no user auth needed |
| FRED | **Free** | 120 requests/min | Free API key from fred.stlouisfed.org |
| Congress.gov | **Free** | No published limit | US government open data |
| Polymarket Gamma API | **Free** | Undocumented, generous | Market metadata + prices |
| Polymarket CLOB API | **Free** | Undocumented | Order book / volume data |

All external data sources are free. The only paid APIs are OpenAI (embeddings + LLM).

---

## Cost 4: Infrastructure

| Component | Small (demo) | Medium | Large |
|---|---|---|---|
| **Compute** (single server) | Free tier / $5/mo | $20/mo (2 vCPU) | $40-80/mo (4 vCPU) |
| **Postgres + pgvector** | Free tier | $15/mo managed | $50/mo managed |
| **Redis** | Free tier | $10/mo | $15/mo |
| **Total infra** | **~$5/mo** | **~$45/mo** | **~$145/mo** |

Elixir/BEAM handles concurrency well — a single 2-vCPU server can comfortably run hundreds of GenServer agents. Scaling compute is the last bottleneck.

---

## Total monthly cost

| Scale | Markets | Embeddings | Synthesis | APIs | Infra | **Total** |
|---|---|---|---|---|---|---|
| **Small** | 5 | $0.54 | $1.14 | $0 | $5 | **~$7/mo** |
| **Medium** | 25 | $1.51 | $9.45 | $0 | $45 | **~$56/mo** |
| **Large** | 100 | $3.89 | $60.48 | $0 | $145 | **~$210/mo** |

---

## Key takeaways

1. **Embeddings are cheap and don't scale with market count.** The global agent fan-out design means adding a new market subscription costs zero incremental embedding spend. This is the single most impactful architectural decision for cost.

2. **LLM synthesis is the dominant variable cost.** At 100 markets it's ~$60/mo — still manageable, but it's the knob to watch. Synthesis frequency and model choice are the primary levers.

3. **All data sources are free.** No API costs beyond OpenAI. Reddit, FRED, Congress.gov, and Polymarket APIs are all free-tier accessible.

4. **Infrastructure costs are modest.** BEAM's concurrency model means a single small server handles the workload up to ~100 markets. Postgres with pgvector handles the vector storage without a separate vector DB.

5. **The cost ceiling is low.** Even at "large" scale (100 simultaneous markets, ~1,800 signals/hour, ~48,000 briefs/month), total cost is ~$210/month. The old per-market swarm architecture would have been ~$600/month at the same scale, with embeddings alone at $389.
