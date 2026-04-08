defmodule OracleWeb.BriefsLive.Index do
  use OracleWeb, :live_view

  alias Oracle.Briefs

  @impl true
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_scope.users.id
    briefs = Briefs.list_for_user(user_id)

    {:ok,
     socket
     |> assign(:briefs, briefs)
     |> assign(:expanded, MapSet.new())
     |> assign(:page_title, "Briefs")}
  end

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    id = String.to_integer(id)
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, id),
        do: MapSet.delete(expanded, id),
        else: MapSet.put(expanded, id)

    {:noreply, assign(socket, :expanded, expanded)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 class="text-2xl font-bold font-mono mb-6 text-primary">Intelligence Briefs</h1>

      <div class="space-y-3">
        <div :for={brief <- @briefs} class="bg-base-200 rounded-lg overflow-hidden">
          <button phx-click="toggle" phx-value-id={brief.id}
                  class="w-full text-left p-4 hover:bg-base-300 transition-colors cursor-pointer">
            <div class="flex justify-between items-start">
              <div class="flex-1 mr-4">
                <div class="text-xs text-base-content/40 font-mono mb-1">
                  {Calendar.strftime(brief.inserted_at, "%b %d, %Y %H:%M UTC")}
                </div>
                <h2 class="text-sm font-semibold">{brief.title || "Untitled Brief"}</h2>
                <.link navigate={~p"/markets/#{brief.market_id}"}
                       class="text-xs text-primary hover:underline font-mono mt-1 block">
                  {brief.market.question}
                </.link>
              </div>
              <div :if={brief.probability_at_generation} class="text-right shrink-0">
                <span class="text-sm font-bold font-mono text-success">
                  {Float.round(brief.probability_at_generation * 100, 1)}%
                </span>
                <div class="text-xs text-base-content/40 font-mono">at generation</div>
              </div>
            </div>
          </button>

          <div :if={MapSet.member?(@expanded, brief.id)} class="px-4 pb-4 border-t border-base-300">
            <p class="text-sm text-base-content/80 whitespace-pre-wrap mt-3">{brief.content}</p>
          </div>
        </div>
      </div>

      <p :if={@briefs == []} class="text-base-content/40 font-mono text-center py-16">
        No briefs yet. Subscribe to markets to start receiving intelligence briefs.
      </p>
    </div>
    """
  end
end
