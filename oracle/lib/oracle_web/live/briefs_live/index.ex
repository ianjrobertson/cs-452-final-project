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
     |> assign(:page_title, "Briefs")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>Intelligence Briefs</.header>

      <div class="space-y-3">
        <div :for={brief <- @briefs} class="collapse collapse-arrow card bg-base-200">
          <input type="checkbox" />
          <div class="collapse-title p-4">
            <div class="flex justify-between items-start">
              <div class="flex-1 mr-4">
                <div class="text-xs text-base-content/40 font-mono mb-1">
                  {Calendar.strftime(brief.inserted_at, "%b %d, %Y %H:%M UTC")}
                </div>
                <h2 class="card-title text-sm">{brief.title || "Untitled Brief"}</h2>
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
          </div>
          <div class="collapse-content px-4 border-t border-base-300">
            <p class="text-sm text-base-content/80 whitespace-pre-wrap mt-3">{brief.content}</p>
          </div>
        </div>
      </div>

      <p :if={@briefs == []} class="text-base-content/40 font-mono text-center py-16">
        No briefs yet. Subscribe to markets to start receiving intelligence briefs.
      </p>
    </Layouts.app>
    """
  end
end
