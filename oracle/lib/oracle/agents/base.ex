defmodule Oracle.Agents.Base do
  defmacro __using__(_opts) do
    quote do
      use GenServer
      @behaviour Oracle.Engine.PollingAgent
      require Logger

      def start_link(opts) do
        GenServer.start_link(__MODULE__, opts)
      end

      @impl true
      def init(opts) do
        state = Map.new(opts)
        send(self(), :poll)
        {:ok, state}
      end

      defoverridable(start_link: 1, init: 1)

      @impl true
      def handle_info(:poll, state) do
        case fetch(state) do
          {:ok, signals} ->
            process_signals(signals)

          {:error, reason} ->
            Logger.warning("An error occured processing signals: #{reason}")
        end

        schedule_work(poll_interval())
        {:noreply, state}
      end

      defp schedule_work(duration) do
        Process.send_after(self(), :poll, duration)
      end

      defp process_signals([]), do: :ok

      defp process_signals(signals) do
        # 1. Batch embed all signals (chunked to avoid API limits)
        embedded_signals =
          signals
          |> Enum.chunk_every(100)
          |> Enum.flat_map(fn batch ->
            texts = Enum.map(batch, &relevance_context/1)
            {:ok, embeddings} = Oracle.Engine.Embeddings.embed_batch(texts)
            Enum.zip(batch, embeddings)
          end)

        # 2. Load all markets that have subscriptions + embeddings
        active_markets = Oracle.Markets.active_market_embeddings()

        # 3. Score each signal against each market, keep relevant pairs
        Enum.each(embedded_signals, fn {signal, embedding} ->
          market_scores =
            for market <- active_markets,
                score = Oracle.Engine.Embeddings.cosine_similarity(embedding, market.question_embedding),
                score > 0.40 do
              {market.id, score}
            end

          # 4. Only insert signals relevant to at least one market
          if market_scores != [] do
            Oracle.Signals.insert(Map.put(signal, :embedding, embedding), market_scores)
          end
        end)
      end
    end
  end
end
