# Oracle — Progress Log

---

## 2026-03-24 — Architecture & Design Decisions Session (~2 hours)

### Summary

Extended design discussion covering data source selection, pipeline architecture, embedding strategy, synthesis agent design, and full-stack architecture diagramming. Several significant departures from the original DESIGN.md were decided.

---

### Decision 1: Drop Broadway Pipeline — Use Direct Function Calls

**Context:** Broadway is designed as a consumer of external message queues (SQS, RabbitMQ, Kafka). The original design had agents calling `Oracle.Pipeline.push/1` to push signals into Broadway, which isn't how Broadway works natively. Writing a custom producer wrapping an in-memory queue defeats the purpose.

**Decision:** Each polling agent handles the full signal lifecycle internally — fetch, embed, score, and write to Postgres. No pipeline abstraction, no message queue. At our actual signal volume (a few hundred per hour), a direct function call with `Task.Supervisor` for async embedding is sufficient.

**Alternatives considered:**
- GenStage (producer/consumer without external broker) — more Elixir-native but added complexity for no throughput benefit
- Redis Streams + Broadway — architecturally clean but another infrastructure dependency in a 6-week project
- Direct function calls (chosen) — simplest, works at our scale

**Future:** Can add GenStage or a queue later if scaling up. The `PollingAgent` behaviour contract doesn't change either way. Redis Streams + Broadway is a good "how I'd scale it" slide for the presentation.

---

### Decision 2: OpenAI `text-embedding-3-small` for Embeddings

**Context:** Needed an embedding strategy for relevance scoring signals against market questions.

**Decision:** Use OpenAI's `text-embedding-3-small` at $0.02/million tokens. At projected volume (5 markets × ~100 signals/hour × 150 tokens average), monthly cost is roughly $1.08.

**Key implementation detail:** Batch embedding calls — send 10-20 signals per API request instead of one-at-a-time. OpenAI's endpoint accepts arrays natively.

**Alternatives considered:**
- Local models (e.g., `all-MiniLM-L6-v2`) — free but requires Python sidecar, produces 384-dim vectors (schema assumes 1536)
- Voyage AI / Cohere — competitive but no advantage over OpenAI for this use case

---

### Decision 3: No RAG — Simple SQL Query for Synthesis

**Context:** The synthesis agent needs to select signals to include in the LLM prompt. Question was whether to use pgvector nearest-neighbor search (RAG-style) or simple SQL.

**Decision:** Simple SQL query: `SELECT * FROM signals WHERE market_id = $1 AND relevance_score > 0.6 ORDER BY ingested_at DESC LIMIT 30`. Signals are already scoped to a market and already relevance-scored at ingest. A semantic retrieval step on top adds complexity for near-zero marginal value.

**Embeddings serve one purpose:** Relevance filtering at ingest time (cosine similarity against market question embedding, threshold at 0.40). By synthesis time, the scores are already computed — just query by score and recency.

**Prompt structure for synthesis:**
```
Market: "{question}"
Current probability: X% (up/down from Y% 24 hours ago)

Recent intelligence signals (ranked by relevance):
1. [source, score] "content..."
2. ...

Synthesize a brief analyzing how these signals affect the market probability.
```

**Future:** pgvector nearest-neighbor search is useful for a cross-market feature like "find signals across all markets similar to this one" — not for single-market synthesis.

---

### Decision 4: Timer-Based Synthesis Trigger (Not Event-Driven)

**Context:** The synthesis agent needs a trigger model. Original design described it as "event-driven" but didn't specify the mechanism.

**Decision:** Use a timer (e.g., every 30 minutes) with a threshold gate. On each tick, check if enough new signals have accumulated since the last brief. If count > threshold (5-10 signals), generate a brief. If not, skip.

**Implementation:** Standard GenServer with `Process.send_after/3`, same pattern as polling agents. Track `last_brief_generated_at` in state and enforce a minimum cooldown (~10 minutes) to prevent LLM call spam during high-volume events.

**Alternatives considered:**
- PubSub-driven reactive approach — polling agents broadcast `{:new_signal, market_id, score}`, synthesis agent keeps a counter, triggers at threshold. Cooler and more Elixir-native, but adds coupling and crash-state complexity (counter resets on restart).
- Could also add a "high urgency" path (single signal with score > 0.90 triggers immediate synthesis) as a future enhancement.

---

### Decision 5: Agent Signal Flow (Updated Architecture)

**Previous:** Agents → Broadway Pipeline → Embed → Score → Store
**Updated:** Each agent handles everything internally:

1. Fetch raw signals from external source
2. Call OpenAI embeddings API (bidirectional — send text, receive vector)
3. Compute cosine similarity against market question embedding
4. If relevance > 0.40, write signal + embedding + score to Postgres
5. Discard if below threshold

```elixir
def handle_info(:poll, state) do
  with {:ok, raw_signals} <- fetch(state.market),
       enriched <- embed_and_score(raw_signals, state.market),
       filtered <- Enum.filter(enriched, & &1.relevance_score > 0.40) do
    Enum.each(filtered, &Oracle.Signals.insert/1)
  end
  schedule_poll(poll_interval())
  {:noreply, %{state | last_polled_at: DateTime.utc_now()}}
end
```

---

### Data Source Evaluation

**Current agents (from DESIGN.md):**
1. NewsAgent — RSS feeds, 5-min polling
2. RedditAgent — Subreddit monitoring, 10-min polling
3. EconomicAgent — FRED macro data, 1-hour polling
4. XAgent — Twitter/X, mocked, 15-min polling
5. PolymarketAgent — Price/metadata sync, 2-min polling (direct DB write, bypasses signal flow)
6. SynthesisAgent — LLM brief generation, timer-based with threshold gate

**RSS feed notes:**
- FT and Bloomberg feeds are paywalled/deprecated — unreliable for programmatic access
- Reuters old URL may no longer resolve
- Recommended: AP News, BBC World, NPR News, Al Jazeera, CNBC (by topic), Politico, The Hill
- RSS is lowest-fidelity source (articles lag events by 30min+). Reddit surfaces breaking signals faster.

**High-value sources to consider adding (ranked):**
1. Congress.gov API — free, structured, covers huge chunk of Polymarket markets (legislation, confirmations, executive orders)
2. Polymarket order book / volume data (CLOB API) — detect abnormal volume or rapid probability shifts as early signals
3. Government data beyond FRED — BLS (jobs), EIA (energy), CDC (health)
4. Wikipedia Recent Changes stream (SSE) — surprisingly fast signal for breaking events
5. Betting odds aggregators (Odds API) — corroborating probability signals from other markets
6. SEC EDGAR filings — real-time filing notifications for company/finance markets

**Deprioritized:** Twitter/X real implementation ($200+/month, most signal gets reposted to Reddit anyway). Keep mocked.

**Build strategy:** Get core pipeline working end-to-end with 2-3 sources first, then add sources incrementally. Architecture makes this trivial — just implement `PollingAgent` and drop into supervision tree.

---

### Architecture Diagram Updates

Created and iterated on a full-stack architecture diagram. Key representation decisions:
- User at top, triggering subscription flow
- Phoenix LiveView connected via PubSub (shown explicitly as intermediary)
- Market room as a visible container showing OTP supervision boundary
- Synthesis agent inside market room (sibling to polling agents, not separate tier)
- Polling agents with bidirectional arrows to OpenAI (embed flow) and single arrow to Postgres
- Polymarket price agent on separate path with direct DB write (bypasses signal pipeline)
- Redis shown as optional cache layer
- Data model tables at bottom (markets, signals, briefs, prob_history, subscriptions)

---

### Open Items / Next Steps

- [ ] Set up Elixir/Phoenix project scaffold
- [ ] Implement Polymarket API integration + market listing UI (Week 1 milestone)
- [ ] Build first polling agent (NewsAgent with reliable RSS feeds)
- [ ] Implement `embed_and_score/2` helper using OpenAI embeddings
- [ ] Decide on Congress.gov API as additional source vs. staying with original 5
- [ ] Update DESIGN.md to reflect Broadway removal and direct function call architecture


Sure. Let me read the current docs first so the summary is grounded in what's actually written.Here's a summary of the architectural decisions made in this session, ready to append to your PROGRESS.md.

---

## 2026-04-02 — Architecture Refinement Session (~1.5 hours)

### Decision 6: Global Source Agents — Eliminate Per-Market Agent Swarms

**Previous:** Each subscribed market spawned its own `MarketRoom.Supervisor` subtree with a full set of polling agents (News, Reddit, Economic, X). 10 active markets meant 10 redundant RSS fetches of identical data.

**Decision:** One global instance of each source agent, shared across all markets. Agents fetch once, embed once, then fan out relevance scoring against all active market question embeddings in a single pass.

The embedding cost reduction is:

$$\text{cost}_{\text{old}} = N_{\text{markets}} \times N_{\text{signals}} \times \text{cost/token}$$

$$\text{cost}_{\text{new}} = N_{\text{signals}} \times \text{cost/token}$$

Adding a new market subscription costs zero incremental fetch or embedding load.

**What's preserved:** The `PollingAgent` behaviour contract is unchanged. OTP fault isolation is unchanged — global agents are still independent GenServers under a supervision tree.

**What's lost:** The `DynamicSupervisor` as a runtime process factory is no longer used for source agents. The supervision tree is now mostly static.

---

### Decision 7: Per-Market SynthesisAgent Under DynamicSupervisor

**Context:** With global source agents, the `DynamicSupervisor` / runtime process factory pattern largely disappears. Brief generation is still genuinely per-market and recovers this pattern.

**Decision:** Keep one dynamically spawned `SynthesisAgent` per active market under a `DynamicSupervisor`. Each instance holds its own timer state, signal threshold counter, and `last_brief_generated_at`. Spawned on subscription, terminated on unsubscribe with no remaining subscribers.

This preserves the interesting OTP pattern where the supervision tree shape changes at runtime based on user activity.

---

### Decision 8: Many-to-Many Signal-to-Market Relationship

**Previous:** `signals` table had a `market_id` foreign key and a `relevance_score` — one signal row per market it was relevant to, duplicating signal data.

**Decision:** Normalize into a join table.

`signals` — signal data and embedding only, no market association:
```
id, source, raw_content, url, embedding (vector), published_at, ingested_at
```

`market_signals` — the relationship, with the score as a property of the relationship:
```
market_id, signal_id, relevance_score
```

`relevance_score` belongs on the join table because the same signal has a different score relative to each market question. Deduplication by URL via a unique index + `ON CONFLICT DO NOTHING` upsert prevents duplicate ingestion across poll cycles.

**Synthesis query becomes:**
```sql
SELECT s.* FROM signals s
JOIN market_signals ms ON ms.signal_id = s.id
WHERE ms.market_id = $1
AND ms.relevance_score > 0.6
ORDER BY s.ingested_at DESC
LIMIT 30
```

Index required: `market_signals(market_id, relevance_score)`.

---

### Decision 9: Topics Generalization (Future / Summer)

**Context:** The global agent + cosine similarity fan-out architecture is not specific to Polymarket. Any question string with an embedding can receive signals.

**Decision:** Deferred to a summer project. The path is straightforward — `markets` becomes `topics` with a `type` enum (`polymarket | custom`). The engine requires no changes. Synthesis prompt adapts based on type: Polymarket topics frame signals against probability movement; custom research topics frame signals as evidence state.

The summer extension also identified a more ambitious agentic loop: a `PlannerAgent` that generates seed URLs and search queries from a research question, feeding a `WebScraperAgent` pool that crawls and embeds arbitrary web content. This introduces a crawl frontier queue, visited-set deduplication, and content extraction (Readability-style) — meaningfully harder than the current architecture and appropriate as a separate project.