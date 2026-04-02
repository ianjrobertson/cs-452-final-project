defmodule Oracle.Agents.PolymarketAgent do
  use GenServer
  alias Oracle.Markets
  alias Oracle.Markets.PolymarketClient
  require Logger

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{})
  end

  @impl true
  def init(state) do
    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    case PolymarketClient.list_active_markets() do
      {:ok, markets} ->
        Enum.each(markets, fn market_attrs ->
          case Markets.upsert(market_attrs) do
            {:ok, market} ->
              Markets.record_probability(market.id, market.probability)
            {:error, reason} ->
              Logger.warning("Failed to upsert market #{inspect(reason)}")
          end
        {:error, reason} ->
          Logger.warning("Failed to fetch markets: #{inspect(reason)}")
        end)
    end
    schedule_work()
    {:noreply, state}
  end

  defp schedule_work do
    Process.send_after(self(), :poll, :timer.minutes(2))
  end
end
