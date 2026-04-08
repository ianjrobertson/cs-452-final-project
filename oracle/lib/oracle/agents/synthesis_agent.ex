defmodule Oracle.Agents.SynthesisAgent do
  use GenServer
  require Logger

  @behaviour Oracle.Engine.SynthesisAgent

  @poll_interval :timer.minutes(2)
  @cooldown_minutes 2

  @system_prompt """
  You are an intelligence analyst for a prediction market platform. Given a market question, \
  its current probability, and a set of recent OSINT signals, write a concise intelligence brief \
  analyzing how these signals affect the likelihood of the market outcome.

  Structure your brief as:
  1. A one-paragraph executive summary of the current outlook
  2. Key bullish signals (evidence the outcome becomes more likely)
  3. Key bearish signals (evidence the outcome becomes less likely)
  4. Assessment of overall signal direction and confidence

  Be specific and cite the signals by number. Keep the brief under 500 words.

  Start your response with a single-line title on its own line, prefixed with "TITLE: ". \
  Then leave a blank line before the body of the brief.
  """

  # -- Client API --

  def start_link(opts) do
    market_id = Keyword.fetch!(opts, :market_id)
    name = {:via, Registry, {Oracle.AgentRegistry, {__MODULE__, market_id}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # -- GenServer callbacks --

  @impl GenServer
  def init(opts) do
    state = %{
      market_id: Keyword.fetch!(opts, :market_id),
      last_brief_at: nil
    }

    schedule_poll()
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    state = run_synthesis_cycle(state)
    schedule_poll()
    {:noreply, state}
  end

  # -- SynthesisAgent behaviour callbacks --

  @impl Oracle.Engine.SynthesisAgent
  def synthesis_threshold, do: 5

  @impl Oracle.Engine.SynthesisAgent
  def build_prompt(market_context, signal_context) do
    probability_pct = Float.round((market_context.probability || 0.0) * 100, 1)

    signal_list =
      signal_context
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {signal, i} ->
        score = Map.get(signal, :relevance_score, "N/A")
        "#{i}. [#{signal.source}, relevance: #{score}] #{signal.title}"
      end)

    """
    Market: "#{market_context.question}"
    Current probability: #{probability_pct}%

    Recent intelligence signals (ranked by relevance):
    #{signal_list}

    Synthesize a brief analyzing how these signals affect the market probability.
    """
  end

  @impl Oracle.Engine.SynthesisAgent
  def parse_response(response) do
    case String.split(response, "\n", parts: 2) do
      ["TITLE: " <> title, body] -> %{title: String.trim(title), content: String.trim(body)}
      _ -> %{title: nil, content: response}
    end
  end

  # -- Private --

  defp run_synthesis_cycle(%{market_id: market_id} = state) do
    since = effective_last_brief_at(state)

    with true <- Oracle.Signals.count_since(market_id, since) >= synthesis_threshold(),
         true <- cooldown_elapsed?(state.last_brief_at) do
      generate_brief(state)
    else
      _ -> state
    end
  end

  defp generate_brief(%{market_id: market_id} = state) do
    market = Oracle.Repo.get!(Oracle.Markets.Market, market_id)
    signals = Oracle.Signals.top_for_market(market_id)

    if signals == [] do
      state
    else
      key_signals =
        Enum.map(signals, fn {signal, score} ->
          %{
            "title" => signal.title,
            "source" => to_string(signal.source),
            "source_url" => signal.source_url,
            "relevance_score" => score
          }
        end)

      # Build signal maps with scores for the prompt builder
      signals_with_scores =
        Enum.map(signals, fn {signal, score} ->
          Map.put(signal, :relevance_score, score)
        end)

      market_context = %{question: market.question, probability: market.probability}
      user_prompt = build_prompt(market_context, signals_with_scores)

      case call_llm_with_retry(user_prompt) do
        {:ok, response_text} ->
          %{title: title, content: content} = parse_response(response_text)
          now = DateTime.utc_now(:second)

          case Oracle.Briefs.insert(%{
                 market_id: market_id,
                 title: title,
                 content: content,
                 key_signals: key_signals,
                 probability_at_generation: market.probability
               }) do
            {:ok, brief} ->
              Phoenix.PubSub.broadcast(Oracle.PubSub, "market:#{market_id}", {:new_brief, brief})
              Logger.info("Generated brief for market #{market_id}")
              %{state | last_brief_at: now}

            {:error, changeset} ->
              Logger.warning("Failed to insert brief for market #{market_id}: #{inspect(changeset.errors)}")
              state
          end

        {:error, reason} ->
          Logger.warning("LLM call failed for market #{market_id}: #{inspect(reason)}, skipping cycle")
          state
      end
    end
  end

  defp call_llm_with_retry(user_prompt) do
    case Oracle.Engine.LLM.chat(@system_prompt, user_prompt) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> Oracle.Engine.LLM.chat(@system_prompt, user_prompt)
    end
  end

  defp effective_last_brief_at(%{last_brief_at: nil, market_id: market_id}) do
    case Oracle.Briefs.latest_for_market(market_id) do
      nil -> DateTime.add(DateTime.utc_now(), -30, :minute)
      brief -> brief.inserted_at
    end
  end

  defp effective_last_brief_at(%{last_brief_at: dt}), do: dt

  defp cooldown_elapsed?(nil), do: true

  defp cooldown_elapsed?(last_brief_at) do
    DateTime.diff(DateTime.utc_now(), last_brief_at, :minute) >= @cooldown_minutes
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end
end
