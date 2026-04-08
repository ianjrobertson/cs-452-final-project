# UI for the Oracle App

### Summary
Bloomberg style dark, terminal app. Yet should have clean, modern UI and design
Scrolling list of tickers

 1. Login / Auth                                                                                                                                                                                                                                                      
  - Dark, minimal sign-in screen. Email + password or OAuth.                                                                                               
  - Gate everything behind authentication.

## Main Pages

### /dashboard
- Overview grid showing your subscribed markets at a glance
- Each market tile: question, current probability, sparkline chart, signal count since last brief, latest brief headline
- Color-coded probability movement (green up, red down)
- Top-level stats: total active markets, recent signal volume

### /markets

Look at current markets. See if the user is subscribed or not. Can subscribe to markets
Simple list interface, includes current probability

- Searchable/filterable table of all tracked Polymarket markets
- Columns: question, category, current probability, 24h change, signal count, subscription status
- Sort/filter by category, probability range, signal activity
- Quick-subscribe action per row

### /markets/:id

Loot at a specific market.
We might want to pull more specific data from polymarket here like a description, maybe even emebed a probability graph, or create a graph from probability history

- The "deep dive" screen for a single market — this is the core Bloomberg-style view
- Left panel: Probability chart (time-series from probability_history), volume/liquidity if available
- Center panel: Latest intelligence brief with key signals highlighted
- Right panel: Live signal feed — scrolling list of recent signals scored against this market, sorted by relevance score
- Subscribe/unsubscribe button, alert threshold slider

### /briefs

Real time list of generated briefs for the user
- Chronological feed of all generated intelligence briefs
- Filter by market or category
- Each brief: market question, timestamp, full LLM-generated analysis, cited signals
- Unread/read tracking

#### /system

Look at current agents that are running
- Agent health monitor — which agents are running, last poll time, error counts
- Supervision tree visualization (simplified)
- Signal ingestion rates per source over time
- Useful for you during development too

### /signals

Real time signals being ingested

- Global firehose of all ingested signals across sources (GDELT, Reddit, FRED, RSS)
- Filterable by source, category, time range, relevance score
- Each signal row: title, source icon, timestamp, top 2-3 matched markets with scores
- Click-through to source URL

---

## Implementation Plan

### Schema Changes (1 migration)

Single migration to cover all UI needs:

1. **Add `title` to `briefs`** — string field, nullable (existing briefs won't have one). Update `SynthesisAgent` prompt to generate a title alongside content.
2. **Add `description` and `image_url` to `markets`** — Polymarket provides both. Update `PolymarketAgent` to pull and store these on upsert.
3. **Add `volume` to `markets`** — float, Polymarket provides this. Useful for Market Terminal.

Schema/changeset updates:
- `Brief` — add `:title` field, include in cast
- `Market` — add `:description` (text), `:image_url` (string), `:volume` (float), include in cast + upsert conflict replace list

Query fix (no migration):
- `Signals.top_for_market/2` — select `relevance_score` from `market_signals` join so Market Terminal can display it

### LiveView Screens (in build order)

Each screen is a LiveView module under `OracleWeb.Live.*`.

#### Phase 1 — Core (get the app usable)

**Step 1: Layout + Auth gate**
- Dark terminal theme via Tailwind (dark bg, monospace accents, green/red for movement)
- Root layout with sidebar nav: Dashboard, Markets, Briefs, Signals, System
- All routes require authenticated user (already have Phoenix auth)

**Step 2: `/markets` — Market Explorer**
- `MarketsLive.Index` — table of all active markets
- Search by question text, filter by category
- Show probability, category, subscription status (icon/button)
- Quick subscribe/unsubscribe action per row
- Simplest screen to build first, validates the full stack

**Step 3: `/markets/:id` — Market Terminal**
- `MarketsLive.Show` — the main Bloomberg-style screen
- Probability chart using probability_history (use a JS chart lib via hook — Chart.js or lightweight alternative)
- Latest brief panel (title + content)
- Signal feed panel — recent signals with relevance scores, linked to source URLs
- Subscribe/unsubscribe button
- Description + image from Polymarket

**Step 4: `/dashboard` — Dashboard**
- `DashboardLive` — grid of subscribed market tiles
- Each tile: question, current probability, mini sparkline, signal count since last brief, latest brief title
- Color-coded probability direction
- Top stats bar: total subscribed markets, total recent signals
- Links to individual market terminals

#### Phase 2 — Supporting screens

**Step 5: `/briefs` — Briefs Feed**
- `BriefsLive.Index` — chronological list of briefs for user's subscribed markets
- Filter by market
- Each entry: market question, brief title, timestamp, expandable content
- No read/unread tracking (keeping it simple)

**Step 6: `/signals` — Signal Feed**
- `SignalsLive.Index` — global signal firehose
- Filter by source type, time range
- Each row: title, source badge, timestamp, top matched markets
- Click-through to source URL

**Step 7: `/system` — System Status**
- `SystemLive` — agent health dashboard
- List running agents from DynamicSupervisor + GlobalSupervisor
- Show agent type, key/category, last poll time
- Runtime data only, no DB schema needed

### Real-time Updates

- PubSub broadcasts already exist for briefs. Extend to:
  - `"market:probability_updated"` — dashboard sparklines + market terminal chart
  - `"signal:new"` — signal feed + market terminal signal panel
- LiveView `handle_info` to push updates without page refresh

### Tech choices

- **Charts**: Chart.js via Phoenix LiveView JS hooks (lightweight, good time-series support)
- **Styling**: Tailwind CSS (already in project) with dark theme utilities
- **No additional JS frameworks** — LiveView handles interactivity

### File structure
```
lib/oracle_web/live/
  dashboard_live.ex
  markets_live/
    index.ex        # /markets
    show.ex         # /markets/:id
  briefs_live/
    index.ex        # /briefs
  signals_live/
    index.ex        # /signals
  system_live.ex    # /system
```

