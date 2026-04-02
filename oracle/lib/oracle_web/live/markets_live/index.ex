defmodule OracleWeb.MarketsLive.Index do
  use OracleWeb, :live_view

  alias Oracle.Markets

  @impl true
  def mount(_params, _session, socket) do
    markets = Markets.list_active()
    {:ok, assign(socket, :markets, markets)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-8">
      <h1 class="text-2xl font-bold mb-6">Active Markets</h1>

      <div class="space-y-4">
        <div :for={market <- @markets} class="border rounded-lg p-4 shadow-sm hover:shadow-md transition-shadow">
          <div class="flex justify-between items-start">
            <h2 class="text-lg font-semibold flex-1 mr-4">{market.question}</h2>
            <span class={[
              "px-2 py-1 rounded text-sm font-medium",
              if(market.active, do: "bg-green-100 text-green-800", else: "bg-gray-100 text-gray-800")
            ]}>
              {if market.active, do: "Active", else: "Closed"}
            </span>
          </div>

          <div class="mt-3 flex items-center gap-6 text-sm text-gray-600">
            <div :if={market.probability} class="flex items-center gap-2">
              <span class="font-medium">Probability:</span>
              <div class="w-32 bg-gray-200 rounded-full h-2.5">
                <div class="bg-blue-600 h-2.5 rounded-full" style={"width: #{round(market.probability * 100)}%"}></div>
              </div>
              <span class="font-semibold">{Float.round(market.probability * 100, 1)}%</span>
            </div>

            <div :if={market.end_date}>
              <span class="font-medium">Ends:</span>
              {Calendar.strftime(market.end_date, "%b %d, %Y")}
            </div>
          </div>
        </div>

        <p :if={@markets == []} class="text-gray-500 text-center py-8">
          No active markets yet. Markets will appear here once the PolymarketAgent syncs data.
        </p>
      </div>
    </div>
    """
  end
end
