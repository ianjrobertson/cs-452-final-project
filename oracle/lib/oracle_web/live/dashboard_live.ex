defmodule OracleWeb.DashboardLive do
  use OracleWeb, :live_view

  alias Oracle.Markets
  alias Oracle.Briefs
  alias Oracle.Signals

  @impl true
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_scope.users.id
    markets = Markets.list_markets_for_user(user_id)

    market_data =
      Enum.map(markets, fn market ->
        brief = Briefs.latest_for_market(market.id)
        signal_count = if brief, do: Signals.count_since(market.id, brief.inserted_at), else: 0

        %{
          market: market,
          brief: brief,
          new_signals: signal_count
        }
      end)

    {:ok,
     socket
     |> assign(:market_data, market_data)
     |> assign(:page_title, "Dashboard")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 class="text-2xl font-bold font-mono mb-2 text-primary">Dashboard</h1>
      <p class="text-sm text-base-content/50 font-mono mb-6">Your subscribed markets</p>

      <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4">
        <.link :for={item <- @market_data}
               navigate={~p"/markets/#{item.market.id}"}
               class="bg-base-200 rounded-lg p-4 hover:bg-base-300 transition-colors block">
          <div class="flex justify-between items-start mb-3">
            <span :if={item.market.category} class="badge badge-xs badge-outline font-mono">{item.market.category}</span>
            <span :if={item.market.probability} class="text-xl font-bold font-mono text-success">
              {Float.round(item.market.probability * 100, 1)}%
            </span>
          </div>

          <h2 class="text-sm font-semibold text-base-content mb-3 leading-tight">{item.market.question}</h2>

          <div class="flex items-center justify-between text-xs text-base-content/50 font-mono">
            <span :if={item.brief}>
              Brief: {String.slice(item.brief.title || item.brief.content, 0..40)}...
            </span>
            <span :if={!item.brief}>No briefs yet</span>
            <span :if={item.new_signals > 0} class="badge badge-xs badge-primary">{item.new_signals} new</span>
          </div>
        </.link>
      </div>

      <p :if={@market_data == []} class="text-base-content/40 font-mono text-center py-16">
        No subscribed markets yet. <.link navigate={~p"/markets"} class="text-primary hover:underline">Browse markets</.link> to get started.
      </p>
    </div>
    """
  end
end
