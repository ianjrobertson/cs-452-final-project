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

      defoverridable(init: 1)

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

      defp process_signals(signals) do
        ## TODO batch embed the signals and then fan out scoring against all active markets
        # check if a market has a subscription to it
        # for each signal, compute cosine similarity agains every market
        # insert relevant pairs to market_signals table
      end
    end
  end
end
