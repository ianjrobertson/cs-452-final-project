defmodule OracleWeb.SignalsLive.Index do
  use OracleWeb, :live_view

  alias Oracle.Signals

  @impl true
  def mount(_params, _session, socket) do
    signals = Signals.list_recent(100)

    {:ok,
     socket
     |> assign(:signals, signals)
     |> assign(:source_filter, nil)
     |> assign(:page_title, "Signals")}
  end

  @impl true
  def handle_event("filter_source", %{"source" => ""}, socket) do
    {:noreply, assign(socket, :source_filter, nil)}
  end

  def handle_event("filter_source", %{"source" => source}, socket) do
    {:noreply, assign(socket, :source_filter, source)}
  end

  defp filtered_signals(signals, nil), do: signals
  defp filtered_signals(signals, source) do
    Enum.filter(signals, &(Atom.to_string(&1.source) == source))
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :filtered, filtered_signals(assigns.signals, assigns.source_filter))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex items-center justify-between">
        <.header>Signal Feed</.header>
        <form phx-change="filter_source">
          <select name="source" class="select select-bordered select-sm bg-base-200 font-mono text-sm">
            <option value="">All Sources</option>
            <option value="news" selected={@source_filter == "news"}>News</option>
            <option value="economic" selected={@source_filter == "economic"}>Economic</option>
            <option value="hacker_news" selected={@source_filter == "hacker_news"}>Hacker News</option>
            <option value="congress" selected={@source_filter == "congress"}>Congress</option>
          </select>
        </form>
      </div>

      <div class="space-y-1">
        <div :for={signal <- @filtered}
             class="card bg-base-200 card-body p-3 flex-row items-start gap-3 hover:bg-base-300 transition-colors">
          <span class={["badge badge-sm font-mono shrink-0 mt-0.5", source_badge(signal.source)]}>
            {signal.source}
          </span>
          <div class="flex-1 min-w-0">
            <%= if signal.source_url do %>
              <a href={signal.source_url} target="_blank" class="text-sm text-primary hover:underline leading-tight block truncate">
                {signal.title || String.slice(signal.content, 0..80)}
              </a>
            <% else %>
              <span class="text-sm text-base-content leading-tight block truncate">
                {signal.title || String.slice(signal.content, 0..80)}
              </span>
            <% end %>
          </div>
          <span class="text-xs text-base-content/40 font-mono shrink-0">
            {Calendar.strftime(signal.inserted_at, "%b %d %H:%M")}
          </span>
        </div>
      </div>

      <p :if={@filtered == []} class="text-base-content/40 font-mono text-center py-16">
        No signals ingested yet.
      </p>
    </Layouts.app>
    """
  end

  defp source_badge(:news), do: "badge-info"
  defp source_badge(:economic), do: "badge-warning"
  defp source_badge(:hacker_news), do: "badge-accent"
  defp source_badge(:congress), do: "badge-secondary"
  defp source_badge(_), do: "badge-ghost"
end
