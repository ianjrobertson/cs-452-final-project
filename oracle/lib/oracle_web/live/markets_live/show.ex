defmodule OracleWeb.MarketsLive.Show do
  use OracleWeb, :live_view

  alias Oracle.Markets
  alias Oracle.Signals
  alias Oracle.Briefs

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    market = Markets.get!(String.to_integer(id))
    history = Markets.probability_history_for(market.id)
    signals = Signals.top_for_market(market.id)
    brief = Briefs.latest_for_market(market.id)
    subscribed = Markets.subscribed?(socket.assigns.current_scope.users.id, market.id)

    {:ok,
     socket
     |> assign(:market, market)
     |> assign(:history, history)
     |> assign(:signals, signals)
     |> assign(:brief, brief)
     |> assign(:subscribed, subscribed)
     |> assign(:page_title, market.question)}
  end

  @impl true
  def handle_event("subscribe", _, socket) do
    user = socket.assigns.current_scope.users
    market = socket.assigns.market

    case Markets.subscribe(user, market) do
      {:ok, _} -> {:noreply, assign(socket, :subscribed, true)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to subscribe")}
    end
  end

  def handle_event("unsubscribe", _, socket) do
    user = socket.assigns.current_scope.users
    market = socket.assigns.market

    case Markets.unsubscribe(user, market) do
      {:ok, _} -> {:noreply, assign(socket, :subscribed, false)}
      _ -> {:noreply, put_flash(socket, :error, "Failed to unsubscribe")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex items-start justify-between mb-6">
        <div>
          <.link navigate={~p"/markets"} class="text-xs text-base-content/50 hover:text-base-content font-mono mb-2 block">
            &larr; Back to Markets
          </.link>
          <h1 class="text-xl font-bold font-mono text-primary">{@market.question}</h1>
          <div class="flex gap-3 mt-2">
            <span :if={@market.category} class="badge badge-sm badge-outline font-mono">{@market.category}</span>
            <span :if={@market.end_date} class="text-xs text-base-content/50 font-mono">
              Ends {Calendar.strftime(@market.end_date, "%b %d, %Y")}
            </span>
          </div>
        </div>
        <div class="flex items-center gap-4">
          <div :if={@market.probability} class="stats bg-base-200">
            <div class="stat py-2 px-4">
              <div class="stat-title font-mono">Current Probability</div>
              <div class="stat-value text-success font-mono">{Float.round(@market.probability * 100, 1)}%</div>
            </div>
          </div>
          <%= if @subscribed do %>
            <button phx-click="unsubscribe" class="btn btn-sm btn-outline btn-error font-mono">Unsubscribe</button>
          <% else %>
            <button phx-click="subscribe" class="btn btn-sm btn-outline btn-success font-mono">Subscribe</button>
          <% end %>
        </div>
      </div>

      <div :if={@market.description} class="card bg-base-200 mb-6">
        <div class="card-body p-4 text-sm text-base-content/70">
          {@market.description}
        </div>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <%!-- Probability Chart --%>
        <div class="card bg-base-200 lg:col-span-2">
          <div class="card-body p-4">
          <h2 class="card-title text-sm font-mono text-base-content/70 uppercase">Probability History</h2>
          <%= if @history != [] do %>
            <div class="h-48 flex items-end gap-px">
              <%= for point <- @history do %>
                <div class="tooltip tooltip-bottom flex-1 h-full flex items-end"
                     data-tip={"#{Float.round(point.probability * 100, 1)}% at #{Calendar.strftime(point.recorded_at, "%b %d %H:%M")}"}>
                  <div class="w-full bg-primary/60 hover:bg-primary rounded-t transition-colors"
                       style={"height: #{point.probability * 100}%"}>
                  </div>
                </div>
              <% end %>
            </div>
          <% else %>
            <p class="text-base-content/40 font-mono text-sm py-8 text-center">No history data yet</p>
          <% end %>
          </div>
        </div>

        <%!-- Market Info --%>
        <div class="card bg-base-200">
          <div class="card-body p-4">
            <h2 class="card-title text-sm font-mono text-base-content/70 uppercase">Market Info</h2>
            <div class="stats stats-vertical bg-base-300 w-full">
              <div :if={@market.volume} class="stat py-2 px-4">
                <div class="stat-title font-mono">Volume</div>
                <div class="stat-value text-lg font-mono">${format_number(@market.volume)}</div>
              </div>
              <div class="stat py-2 px-4">
                <div class="stat-title font-mono">Status</div>
                <div class={["stat-value text-lg font-mono", if(@market.active, do: "text-success", else: "text-error")]}>
                  {if @market.active, do: "Active", else: "Closed"}
                </div>
              </div>
            </div>
            <div :if={@market.image_url}>
              <img src={@market.image_url} class="rounded mt-2 w-full" />
            </div>
          </div>
        </div>

        <%!-- Latest Brief --%>
        <div class="card bg-base-200 lg:col-span-2">
          <div class="card-body p-4">
            <h2 class="card-title text-sm font-mono text-base-content/70 uppercase">Latest Brief</h2>
            <%= if @brief do %>
              <div>
                <h3 :if={@brief.title} class="font-bold text-base-content mb-2">{@brief.title}</h3>
                <p class="text-sm text-base-content/80 whitespace-pre-wrap">{@brief.content}</p>
                <div class="mt-3 text-xs text-base-content/40 font-mono">
                  Generated {Calendar.strftime(@brief.inserted_at, "%b %d, %Y %H:%M UTC")}
                  · Probability at generation: {Float.round(@brief.probability_at_generation * 100, 1)}%
                </div>
              </div>
            <% else %>
              <p class="text-base-content/40 font-mono text-sm py-4 text-center">No briefs generated yet</p>
            <% end %>
          </div>
        </div>

        <%!-- Signal Feed --%>
        <div class="card bg-base-200">
          <div class="card-body p-4">
            <h2 class="card-title text-sm font-mono text-base-content/70 uppercase">Top Signals</h2>
            <div class="space-y-3 max-h-96 overflow-y-auto">
              <%= for {signal, score} <- @signals do %>
                <div class="border-b border-base-300 pb-2">
                  <div class="flex justify-between items-start">
                    <a :if={signal.source_url} href={signal.source_url} target="_blank"
                       class="text-sm text-primary hover:underline leading-tight">
                      {signal.title || String.slice(signal.content, 0..60)}
                    </a>
                    <span :if={!signal.source_url} class="text-sm text-base-content leading-tight">
                      {signal.title || String.slice(signal.content, 0..60)}
                    </span>
                    <span class="badge badge-xs font-mono ml-2 shrink-0">
                      {Float.round(score, 2)}
                    </span>
                  </div>
                  <div class="text-xs text-base-content/40 font-mono mt-1">
                    {signal.source} · {Calendar.strftime(signal.inserted_at, "%b %d %H:%M")}
                  </div>
                </div>
              <% end %>
              <p :if={@signals == []} class="text-base-content/40 font-mono text-sm py-4 text-center">No signals yet</p>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_number(n), do: "#{Float.round(n, 0)}"
end
