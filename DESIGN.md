# Oracle — Agent Architecture & Data Source Design

> This document covers the agent behaviour contracts, supervision tree structure, per-source agent specifications, signal data model, and error handling strategy.

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Agent Behaviour Contracts](#2-agent-behaviour-contracts)
3. [Supervision Tree Structure](#3-supervision-tree-structure)
4. [Per-Source Agent Specifications](#4-per-source-agent-specifications)
5. [Signal Data Model](#5-signal-data-model)
6. [Error Handling & Retry Strategy](#6-error-handling--retry-strategy)

---

## 1. System Overview

Oracle is built on two distinct layers:

**Layer 1 — The Engine (generic, source-agnostic)**
The engine defines the contracts, pipeline, and infrastructure that any agent must conform to. It has zero knowledge of Polymarket, Reddit, or any specific data source. Swapping a vertical is a matter of implementing behaviours and configuring the supervision tree.

**Layer 2 — The Vertical (Oracle / Polymarket OSINT)**
Concrete implementations of the engine's behaviours. Each data source agent implements the `PollingAgent` behaviour. The synthesis agent implements the `SynthesisAgent` behaviour. The vertical wires these into a market-scoped supervision subtree.

The runtime flow for a single subscribed market:

```
User subscribes to a market
        │
        ▼
DynamicSupervisor spawns a MarketRoom.Supervisor
        │
        ├── NewsAgent (GenServer)        ──┐
        ├── RedditAgent (GenServer)       │
        ├── EconomicAgent (GenServer)     ├──► Broadway Pipeline
        ├── XAgent (GenServer)           ──┘       │
        │                                          ▼
        └── SynthesisAgent (GenServer)  ◄── scored signals in Postgres
                    │
                    ▼
            Phoenix PubSub broadcast
                    │
                    ▼
            LiveView dashboard update
```

Each agent runs on its own polling schedule, pushes raw signals into the Broadway pipeline, and is supervised independently. A crashed agent restarts without affecting sibling agents or other market rooms.

---

## 2. Agent Behaviour Contracts

Elixir behaviours define the interface every agent must implement. This is the core abstraction that makes the engine generic.

### 2.1 `PollingAgent` Behaviour

Every data source agent must implement this behaviour. It defines:
- How to fetch signals for a given topic
- How to produce a relevance context string (used for embedding similarity)
- The polling interval

```elixir
defmodule Oracle.Engine.PollingAgent do
  @moduledoc """
  Behaviour contract for all data source polling agents.

  A PollingAgent is responsible for:
  - Fetching raw signals from a single external source
  - Normalising those signals into the shared Signal struct
  - Declaring a polling interval and relevance context

  Implementors should not concern themselves with embedding,
  scoring, or persistence — those are handled by the Broadway pipeline.
  """

  @type topic :: %{
    id: String.t(),
    question: String.t(),
    keywords: [String.t()],
    category: String.t()
  }

  @type raw_signal :: %{
    source: atom(),
    raw_content: String.t(),
    url: String.t() | nil,
    published_at: DateTime.t()
  }

  @doc """
  Fetch new signals relevant to the given topic.
  Returns a list of raw signal maps to be pushed into the pipeline.
  """
  @callback fetch(topic()) :: {:ok, [raw_signal()]} | {:error, term()}

  @doc """
  Returns a string that contextualises what this agent monitors.
  Used during embedding to weight relevance scoring.
  Example: "Recent news articles about Fed interest rate decisions"
  """
  @callback relevance_context(topic()) :: String.t()

  @doc """
  How frequently (in milliseconds) this agent should poll.
  Agents may define different intervals based on source volatility.
  """
  @callback poll_interval() :: pos_integer()
end
```

### 2.2 `SynthesisAgent` Behaviour

The synthesis agent consumes scored signals and produces a structured brief via LLM. It implements a separate behaviour since its trigger model differs — it is event-driven (new signals above a threshold) rather than time-driven.

```elixir
defmodule Oracle.Engine.SynthesisAgent do
  @moduledoc """
  Behaviour contract for synthesis agents.

  A SynthesisAgent consumes a batch of scored signals for a market
  and produces a structured intelligence brief via LLM.

  Implementors define:
  - How to build the prompt for the LLM
  - How to parse and validate the LLM response into a Brief struct
  - The minimum signal count and relevance threshold to trigger synthesis
  """

  @type signal :: Oracle.Signals.Signal.t()
  @type topic  :: Oracle.Engine.PollingAgent.topic()

  @type brief :: %{
    summary_text: String.t(),
    key_signals: [map()],
    sentiment_direction: :bullish | :bearish | :neutral | :unclear,
    generated_at: DateTime.t()
  }

  @doc """
  Build the LLM prompt given a topic and a list of relevant signals.
  """
  @callback build_prompt(topic(), [signal()]) :: String.t()

  @doc """
  Parse the raw LLM response string into a Brief struct.
  Returns {:error, reason} if the response is malformed.
  """
  @callback parse_response(String.t()) :: {:ok, brief()} | {:error, term()}

  @doc """
  Minimum number of unprocessed signals required to trigger synthesis.
  Prevents wasteful LLM calls when signal volume is low.
  """
  @callback synthesis_threshold() :: pos_integer()
end
```

---

## 3. Supervision Tree Structure

### 3.1 Full Tree

```
Oracle.Application
└── Oracle.Supervisor (top-level, strategy: :one_for_one)
    ├── Oracle.Repo                          (Ecto / Postgres)
    ├── Oracle.Cache                         (Redis via Redix)
    ├── Oracle.PubSub                        (Phoenix.PubSub)
    ├── Oracle.Pipeline.Supervisor           (Broadway pipeline)
    └── Oracle.Markets.RoomSupervisor        (DynamicSupervisor)
        ├── Oracle.MarketRoom.Supervisor [market_id: "abc"] 
        │   ├── Oracle.Agents.NewsAgent
        │   ├── Oracle.Agents.RedditAgent
        │   ├── Oracle.Agents.EconomicAgent
        │   ├── Oracle.Agents.XAgent
        │   └── Oracle.Agents.SynthesisAgent
        └── Oracle.MarketRoom.Supervisor [market_id: "xyz"]
            ├── Oracle.Agents.NewsAgent
            ├── Oracle.Agents.RedditAgent
            ├── Oracle.Agents.EconomicAgent
            ├── Oracle.Agents.XAgent
            └── Oracle.Agents.SynthesisAgent
```

### 3.2 `RoomSupervisor` — Dynamic Market Room Spawning

`RoomSupervisor` is a `DynamicSupervisor`. When a user subscribes to a market, the application calls `RoomSupervisor.start_room/1`, which spawns a new `MarketRoom.Supervisor` subtree for that market. When a user unsubscribes and no other users are watching, the subtree is terminated.

```elixir
defmodule Oracle.Markets.RoomSupervisor do
  use DynamicSupervisor

  def start_link(_), do: DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)

  def init(_), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_room(market) do
    spec = {Oracle.MarketRoom.Supervisor, market: market}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def stop_room(market_id) do
    case find_room_pid(market_id) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      :not_found -> :ok
    end
  end
end
```

### 3.3 `MarketRoom.Supervisor` — Per-Market Agent Tree

Each market room supervisor starts all agents for that market under a `:one_for_one` strategy. If one agent crashes, only that agent restarts — the other agents and the market room itself remain unaffected.

```elixir
defmodule Oracle.MarketRoom.Supervisor do
  use Supervisor

  def start_link(opts) do
    market = Keyword.fetch!(opts, :market)
    Supervisor.start_link(__MODULE__, market, name: via(market.id))
  end

  def init(market) do
    children = [
      {Oracle.Agents.NewsAgent,     market: market},
      {Oracle.Agents.RedditAgent,   market: market},
      {Oracle.Agents.EconomicAgent, market: market},
      {Oracle.Agents.XAgent,        market: market},
      {Oracle.Agents.SynthesisAgent, market: market}
    ]
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp via(market_id), do: {:via, Registry, {Oracle.MarketRegistry, market_id}}
end
```

### 3.4 Restart Strategy Rationale

| Supervisor | Strategy | Reasoning |
|---|---|---|
| `Oracle.Supervisor` | `:one_for_one` | Top-level services are independent |
| `RoomSupervisor` | `:one_for_one` | Market rooms are independent of each other |
| `MarketRoom.Supervisor` | `:one_for_one` | Agents are independent; a Reddit crash shouldn't restart NewsAgent |

---

## 4. Per-Source Agent Specifications

Each agent is a GenServer that schedules its own polling via `Process.send_after/3`. On each poll it calls `fetch/1`, normalises the results, and pushes them into the Broadway pipeline.

### 4.1 Base GenServer Pattern

All polling agents share this pattern. The behaviour callbacks (`fetch/1`, `relevance_context/1`, `poll_interval/0`) are the only things that differ per source.

```elixir
defmodule Oracle.Agents.Base do
  @moduledoc """
  Shared GenServer scaffolding for all PollingAgent implementations.
  Concrete agents `use Oracle.Agents.Base` and implement the PollingAgent behaviour.
  """

  defmacro __using__(_opts) do
    quote do
      use GenServer
      @behaviour Oracle.Engine.PollingAgent

      def start_link(opts) do
        market = Keyword.fetch!(opts, :market)
        GenServer.start_link(__MODULE__, market)
      end

      def init(market) do
        schedule_poll(poll_interval())
        {:ok, %{market: market, last_polled_at: nil}}
      end

      def handle_info(:poll, state) do
        case fetch(state.market) do
          {:ok, signals} ->
            Enum.each(signals, &Oracle.Pipeline.push(&1))
          {:error, reason} ->
            # Logged and handled in error strategy — see Section 6
            Oracle.Pipeline.record_failure(__MODULE__, reason, state.market.id)
        end
        schedule_poll(poll_interval())
        {:noreply, %{state | last_polled_at: DateTime.utc_now()}}
      end

      defp schedule_poll(interval) do
        Process.send_after(self(), :poll, interval)
      end
    end
  end
end
```

---

### 4.2 News Agent (RSS)

**Purpose:** Ingest structured news articles from major outlets via RSS feeds.

**Data sources:**

| Feed | URL | Coverage |
|---|---|---|
| Reuters Top News | `https://feeds.reuters.com/reuters/topNews` | General world news |
| AP News | `https://feeds.apnews.com/rss/apf-topnews` | Breaking news |
| BBC News | `http://feeds.bbci.co.uk/news/rss.xml` | International |
| Financial Times | `https://www.ft.com/rss/home` | Finance / macro |
| Bloomberg (free) | `https://feeds.bloomberg.com/markets/news.rss` | Markets |

**Implementation notes:**
- Parse RSS/Atom XML using `Quinn` or `SweetXml` (Elixir XML parsing libraries)
- Deduplicate by URL before pushing to pipeline
- Extract: title, description/summary, link, pubDate

**Spec:**

```
poll_interval:     5 minutes (300_000 ms)
auth_required:     No
rate_limit:        None (RSS is pull-based)
cost:              Free
signal_volume:     Low–Medium (5–30 articles per poll across all feeds)

raw_signal fields:
  source:          :news
  raw_content:     "<title>. <description>"
  url:             article link
  published_at:    parsed from pubDate
```

**Implementation skeleton:**

```elixir
defmodule Oracle.Agents.NewsAgent do
  use Oracle.Agents.Base

  @feeds [
    "https://feeds.reuters.com/reuters/topNews",
    "https://feeds.apnews.com/rss/apf-topnews",
    "http://feeds.bbci.co.uk/news/rss.xml"
  ]

  @impl Oracle.Engine.PollingAgent
  def poll_interval, do: :timer.minutes(5)

  @impl Oracle.Engine.PollingAgent
  def relevance_context(topic) do
    "Recent news articles relevant to: #{topic.question}"
  end

  @impl Oracle.Engine.PollingAgent
  def fetch(topic) do
    signals =
      @feeds
      |> Enum.flat_map(&fetch_feed/1)
      |> Enum.map(&normalise(&1, topic))
      |> Enum.uniq_by(& &1.url)

    {:ok, signals}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp fetch_feed(url) do
    # HTTP GET + RSS XML parse
    # Returns list of %{title, description, link, pub_date}
  end

  defp normalise(item, _topic) do
    %{
      source: :news,
      raw_content: "#{item.title}. #{item.description}",
      url: item.link,
      published_at: item.pub_date
    }
  end
end
```

---

### 4.3 Reddit Agent

**Purpose:** Monitor relevant subreddits for community sentiment and crowd-sourced signals.

**Target subreddits by market category:**

| Category | Subreddits |
|---|---|
| Finance / macro | r/investing, r/economics, r/wallstreetbets, r/stocks |
| Politics / geopolitics | r/worldnews, r/geopolitics, r/politics |
| Science / tech | r/science, r/technology, r/MachineLearning |
| Sports | r/nba, r/nfl, r/soccer (mapped per market category) |

Subreddit targeting is driven by the market's `category` field — the agent selects the relevant subreddit list at init time.

**Authentication:** OAuth 2.0 (client credentials flow — no user login required for read-only access). Register an app at reddit.com/prefs/apps to get `client_id` and `client_secret`.

**Key endpoints:**

```
GET /r/{subreddit}/new.json?limit=25    # New posts
GET /r/{subreddit}/search.json          # Keyword search within subreddit
  ?q={keyword}&sort=new&limit=25&t=day
```

**Spec:**

```
poll_interval:     10 minutes (600_000 ms)
auth_required:     Yes — OAuth 2.0 client credentials
rate_limit:        100 QPM (free tier, non-commercial)
cost:              Free (non-commercial use)
signal_volume:     Medium (10–50 posts per poll)

raw_signal fields:
  source:          :reddit
  raw_content:     "r/{subreddit}: {title}. {selftext | ""}"
  url:             "https://reddit.com{permalink}"
  published_at:    DateTime.from_unix!(created_utc)
```

**Token refresh strategy:** Reddit OAuth tokens expire after 1 hour. The agent stores the token and expiry in its GenServer state and silently refreshes before each poll if within 5 minutes of expiry.

---

### 4.4 Economic Indicators Agent (FRED)

**Purpose:** Ingest macro economic data releases from the Federal Reserve Economic Data API. Provides hard data signals (CPI, unemployment, interest rates, GDP) rather than sentiment.

**API:** [api.stlouisfed.org](https://fred.stlouisfed.org/docs/api/fred/) — free, requires API key (register at fred.stlouisfed.org).

**Key series monitored:**

| Series ID | Indicator | Release frequency |
|---|---|---|
| `FEDFUNDS` | Federal funds rate | Monthly |
| `CPIAUCSL` | CPI (inflation) | Monthly |
| `UNRATE` | Unemployment rate | Monthly |
| `GDP` | Gross Domestic Product | Quarterly |
| `DGS10` | 10-year Treasury yield | Daily |
| `DEXUSEU` | USD/EUR exchange rate | Daily |

Series monitored are filtered by market category — a sports market won't poll economic indicators.

**Key endpoint:**

```
GET https://api.stlouisfed.org/fred/series/observations
  ?series_id={SERIES_ID}
  &api_key={KEY}
  &sort_order=desc
  &limit=1
  &file_type=json
```

**Spec:**

```
poll_interval:     1 hour (3_600_000 ms) — data releases are infrequent
auth_required:     Yes — API key (free)
rate_limit:        120 requests/minute (generous)
cost:              Free
signal_volume:     Very low (1–5 data points per poll, only on release days)

raw_signal fields:
  source:          :economic
  raw_content:     "{series_name}: {value} as of {date}"
  url:             "https://fred.stlouisfed.org/series/{series_id}"
  published_at:    parsed release date from observation
```

**Note:** The economic agent only pushes a signal when the observed value has *changed* since the last poll. This prevents flooding the pipeline with duplicate data on non-release days.

---

### 4.5 X / Twitter Agent (Mocked)

**Status:** Mocked for initial development due to API cost ($200+/month for Basic tier). The mock agent produces realistic synthetic signals that exercise the full pipeline. A real implementation can be swapped in by replacing `fetch/1` without touching anything else.

**Mock behaviour:** Generates plausible-looking signal structs based on the market question keywords, with randomised timestamps and sentiment. Useful for end-to-end pipeline testing.

```elixir
defmodule Oracle.Agents.XAgent do
  use Oracle.Agents.Base

  @impl Oracle.Engine.PollingAgent
  def poll_interval, do: :timer.minutes(15)

  @impl Oracle.Engine.PollingAgent
  def relevance_context(topic) do
    "Social media posts and commentary about: #{topic.question}"
  end

  @impl Oracle.Engine.PollingAgent
  def fetch(topic) do
    # TODO: Replace with real X API v2 search when budget allows
    # Endpoint: GET /2/tweets/search/recent?query={keywords}&max_results=10
    signals = Oracle.Agents.XMock.generate(topic)
    {:ok, signals}
  end
end
```

**Real implementation notes (for future):**
- Endpoint: `GET /2/tweets/search/recent`
- Auth: Bearer token (OAuth 2.0 App-Only)
- Query: join `topic.keywords` with OR, filter `lang:en`, exclude retweets
- Cost: X Basic tier at $200/month, or pay-per-use credits (launched Feb 2026)

---

### 4.6 Polymarket Agent

**Purpose:** Not an OSINT source — this agent syncs market metadata and probability history from Polymarket's Gamma API. It is the *topic source*, not a signal source.

**Key endpoints:**

```
GET https://gamma-api.polymarket.com/markets?active=true&limit=50
GET https://gamma-api.polymarket.com/markets/{condition_id}
GET https://clob.polymarket.com/prices-history?token_id={id}&interval=1d
```

**Spec:**

```
poll_interval:     2 minutes (120_000 ms) for probability updates
auth_required:     No (public read-only)
rate_limit:        Not published — implement exponential backoff
cost:              Free
output:            Updates markets table + appends to probability_history
```

This agent writes to `markets` and `probability_history` tables directly, bypassing the signal pipeline (probability data is not a signal to be scored).

---

## 5. Signal Data Model

### 5.1 Ecto Schemas

#### `signals`
The core table. Every piece of ingested OSINT from any source lands here after pipeline processing.

```elixir
defmodule Oracle.Signals.Signal do
  use Ecto.Schema
  import Ecto.Changeset

  schema "signals" do
    field :source,          Ecto.Enum, values: [:news, :reddit, :economic, :twitter]
    field :raw_content,     :string
    field :url,             :string
    field :relevance_score, :float         # cosine similarity vs market embedding, 0.0–1.0
    field :embedding,       Pgvector.Ecto.Vector, size: 1536  # OpenAI/Claude embedding dims
    field :published_at,    :utc_datetime
    field :ingested_at,     :utc_datetime

    belongs_to :market, Oracle.Markets.Market

    timestamps()
  end

  def changeset(signal, attrs) do
    signal
    |> cast(attrs, [:source, :raw_content, :url, :relevance_score,
                    :embedding, :published_at, :ingested_at, :market_id])
    |> validate_required([:source, :raw_content, :market_id, :ingested_at])
    |> validate_number(:relevance_score, greater_than_or_equal_to: 0.0,
                                         less_than_or_equal_to: 1.0)
  end
end
```

#### `markets`

```elixir
defmodule Oracle.Markets.Market do
  use Ecto.Schema

  schema "markets" do
    field :polymarket_id,       :string
    field :question,            :string
    field :category,            :string
    field :current_probability, :float
    field :question_embedding,  Pgvector.Ecto.Vector, size: 1536
    field :keywords,            {:array, :string}
    field :last_synced_at,      :utc_datetime

    has_many :signals,              Oracle.Signals.Signal
    has_many :briefs,               Oracle.Briefs.Brief
    has_many :probability_history,  Oracle.Markets.ProbabilityHistory
    has_many :user_subscriptions,   Oracle.Subscriptions.UserSubscription

    timestamps()
  end
end
```

#### `briefs`

```elixir
defmodule Oracle.Briefs.Brief do
  use Ecto.Schema

  schema "briefs" do
    field :summary_text,       :string
    field :key_signals,        :map          # JSONB — list of {source, excerpt, score}
    field :sentiment_direction, Ecto.Enum,
          values: [:bullish, :bearish, :neutral, :unclear]
    field :signal_count,       :integer      # how many signals informed this brief
    field :generated_at,       :utc_datetime

    belongs_to :market, Oracle.Markets.Market

    timestamps()
  end
end
```

#### `probability_history`

```elixir
defmodule Oracle.Markets.ProbabilityHistory do
  use Ecto.Schema

  schema "probability_history" do
    field :probability,  :float
    field :recorded_at,  :utc_datetime

    belongs_to :market, Oracle.Markets.Market
  end
end
```

#### `user_subscriptions`

```elixir
defmodule Oracle.Subscriptions.UserSubscription do
  use Ecto.Schema

  schema "user_subscriptions" do
    field :alert_threshold, :float, default: 0.75  # relevance score to trigger alert
    field :alert_enabled,   :boolean, default: true

    belongs_to :user,   Oracle.Accounts.User
    belongs_to :market, Oracle.Markets.Market

    timestamps()
  end
end
```

### 5.2 Indexes

```sql
-- Fast lookup of signals per market, ordered by recency
CREATE INDEX signals_market_id_ingested_at ON signals (market_id, ingested_at DESC);

-- pgvector index for embedding similarity search
CREATE INDEX signals_embedding_idx ON signals
  USING ivfflat (embedding vector_cosine_ops)
  WITH (lists = 100);

-- Probability history time-series queries
CREATE INDEX prob_history_market_recorded ON probability_history (market_id, recorded_at DESC);
```

### 5.3 Relevance Scoring

Relevance is computed as cosine similarity between the signal embedding and the market question embedding:

$$\text{relevance}(s, m) = \frac{\vec{s} \cdot \vec{m}}{|\vec{s}||\vec{m}|}$$

Where $\vec{s}$ is the signal's embedding vector and $\vec{m}$ is the market question's pre-computed embedding vector stored on the `markets` table.

Signals with `relevance_score < 0.40` are discarded at the pipeline stage and never written to the database.

---

## 6. Error Handling & Retry Strategy

### 6.1 Principles

- **Let it crash.** OTP supervision handles restarts. Agents do not swallow errors that would leave state corrupted — they crash and restart cleanly.
- **Retry transient failures.** Network timeouts, rate limit responses (429), and temporary API unavailability are retried with exponential backoff.
- **Discard corrupt data.** Malformed API responses or unparseable signals are logged and discarded — they do not crash the agent.
- **Circuit break persistent failures.** If an agent fails repeatedly within a short window, the supervisor's restart intensity kicks in and backs off.

### 6.2 HTTP Retry Logic

All HTTP calls use a shared retry wrapper. The strategy:

```
Attempt 1:  immediate
Attempt 2:  wait 1s
Attempt 3:  wait 2s
Attempt 4:  wait 4s  (give up after this)
```

Retryable status codes: `429`, `500`, `502`, `503`, `504`
Non-retryable: `400`, `401`, `403`, `404` (crash or log and skip)

```elixir
defmodule Oracle.HTTP do
  @max_attempts 4
  @base_delay_ms 1_000

  def get_with_retry(url, headers \\ [], attempt \\ 1) do
    case HTTPoison.get(url, headers) do
      {:ok, %{status_code: code} = resp} when code in 200..299 ->
        {:ok, resp}

      {:ok, %{status_code: 429}} when attempt < @max_attempts ->
        delay = @base_delay_ms * :math.pow(2, attempt - 1) |> round()
        Process.sleep(delay)
        get_with_retry(url, headers, attempt + 1)

      {:ok, %{status_code: code}} ->
        {:error, {:http_error, code}}

      {:error, %HTTPoison.Error{reason: reason}} when attempt < @max_attempts ->
        delay = @base_delay_ms * :math.pow(2, attempt - 1) |> round()
        Process.sleep(delay)
        get_with_retry(url, headers, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

### 6.3 Supervisor Restart Intensity

OTP supervisors are configured with a restart intensity to prevent infinite crash loops. If an agent crashes more than 3 times within 5 seconds, the supervisor itself terminates and propagates the failure upward.

```elixir
# In MarketRoom.Supervisor
Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 5)
```

For the top-level `RoomSupervisor` (DynamicSupervisor), a crashed `MarketRoom.Supervisor` is restarted. If the room continues to crash, it is eventually removed and the market is flagged as `status: :error` in the database.

### 6.4 Broadway Pipeline Error Handling

Broadway provides built-in failure handling for the ingest pipeline. Failed messages are retried up to 3 times before being sent to a dead-letter handler that logs the failure and discards the message.

```elixir
defmodule Oracle.Pipeline do
  use Broadway

  # ...

  @impl true
  def handle_failed(messages, _context) do
    Enum.each(messages, fn msg ->
      Logger.error("Pipeline failure", reason: msg.status, data: msg.data)
    end)
    messages  # Acknowledge (discard) failed messages
  end
end
```

### 6.5 Error Surface Summary

| Failure type | Where caught | Action |
|---|---|---|
| HTTP timeout / 5xx | `Oracle.HTTP` retry wrapper | Exponential backoff, up to 4 attempts |
| HTTP 429 rate limit | `Oracle.HTTP` retry wrapper | Backoff + retry |
| HTTP 401/403 auth failure | Agent `fetch/1` | `{:error, :auth_failure}` — log, skip poll |
| Malformed API response | Agent `fetch/1` | Log + return `{:ok, []}` (empty, no crash) |
| Pipeline processing failure | Broadway `handle_failed` | Log + discard |
| Agent crash (unexpected) | `MarketRoom.Supervisor` | Restart up to 3× in 5s |
| Repeated agent crashes | `MarketRoom.Supervisor` | Supervisor terminates, room flagged in DB |
| LLM API failure (synthesis) | `SynthesisAgent` | Retry once; if fails, skip this synthesis cycle |

---

*Design Document v0.1 — [Your Name] — [Course Name] — [Date]*
