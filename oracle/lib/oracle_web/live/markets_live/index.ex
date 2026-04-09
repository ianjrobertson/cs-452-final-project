defmodule OracleWeb.MarketsLive.Index do
  use OracleWeb, :live_view

  alias Oracle.Markets

  @impl true
  def mount(_params, _session, socket) do
    markets = Markets.list_active()
    categories = Markets.list_categories()

    {:ok,
     socket
     |> assign(:markets, markets)
     |> assign(:categories, categories)
     |> assign(:search, "")
     |> assign(:category_filter, nil)
     |> assign(:page_title, "Markets")}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, assign(socket, :search, search)}
  end

  def handle_event("filter_category", %{"category" => ""}, socket) do
    {:noreply, assign(socket, :category_filter, nil)}
  end

  def handle_event("filter_category", %{"category" => category}, socket) do
    {:noreply, assign(socket, :category_filter, category)}
  end

  def handle_event("subscribe", %{"id" => id}, socket) do
    market = Markets.get!(String.to_integer(id))
    user = socket.assigns.current_scope.users

    case Markets.subscribe(user, market) do
      {:ok, _sub} ->
        {:noreply,
         socket
         |> put_flash(:info, "Subscribed to market")
         |> assign(:markets, Markets.list_active())}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to subscribe")}
    end
  end

  def handle_event("unsubscribe", %{"id" => id}, socket) do
    market = Markets.get!(String.to_integer(id))
    user = socket.assigns.current_scope.users

    case Markets.unsubscribe(user, market) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Unsubscribed from market")
         |> assign(:markets, Markets.list_active())}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to unsubscribe")}
    end
  end

  defp filtered_markets(markets, search, category_filter) do
    markets
    |> Enum.filter(fn m ->
      (category_filter == nil or m.category == category_filter) and
        (search == "" or String.contains?(String.downcase(m.question), String.downcase(search)))
    end)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :filtered_markets, filtered_markets(assigns.markets, assigns.search, assigns.category_filter))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>Markets</.header>

      <div class="flex gap-4 mb-6">
        <input
          type="text"
          placeholder="Search markets..."
          value={@search}
          phx-keyup="search"
          phx-key="Enter"
          phx-debounce="300"
          class="input input-bordered bg-base-200 font-mono text-sm flex-1"
        />
        <select phx-change="filter_category" name="category" class="select select-bordered bg-base-200 font-mono text-sm">
          <option value="">All Categories</option>
          <option :for={cat <- @categories} value={cat} selected={@category_filter == cat}>{cat}</option>
        </select>
      </div>

      <div class="overflow-x-auto">
        <table class="table table-sm font-mono">
          <thead>
            <tr class="text-base-content/50 text-xs uppercase">
              <th>Market</th>
              <th>Category</th>
              <th>Probability</th>
              <th>End Date</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={market <- @filtered_markets}
                class="hover:bg-base-200 cursor-pointer border-b border-base-300"
                phx-click={JS.navigate(~p"/markets/#{market.id}")}>
              <td class="max-w-md">
                <div class="text-sm">{market.question}</div>
              </td>
              <td>
                <span :if={market.category} class="badge badge-sm badge-outline font-mono">
                  {market.category}
                </span>
              </td>
              <td>
                <span :if={market.probability} class={[
                  "font-bold",
                  probability_color(market.probability)
                ]}>
                  {format_probability(market.probability)}
                </span>
              </td>
              <td class="text-xs text-base-content/50">
                {if market.end_date, do: Calendar.strftime(market.end_date, "%b %d, %Y")}
              </td>
              <td>
                <%= if Markets.subscribed?(@current_scope.users.id, market.id) do %>
                  <button phx-click="unsubscribe" phx-value-id={market.id}
                          class="btn btn-xs btn-outline btn-error font-mono">
                    Unsub
                  </button>
                <% else %>
                  <button phx-click="subscribe" phx-value-id={market.id}
                          class="btn btn-xs btn-outline btn-success font-mono">
                    Subscribe
                  </button>
                <% end %>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <p :if={@filtered_markets == []} class="text-base-content/50 text-center py-8 font-mono">
        No markets found.
      </p>
    </Layouts.app>
    """
  end

  defp format_probability(p), do: "#{Float.round(p * 100, 1)}%"

  defp probability_color(p) when p >= 0.7, do: "text-success"
  defp probability_color(p) when p <= 0.3, do: "text-error"
  defp probability_color(_), do: "text-warning"
end
