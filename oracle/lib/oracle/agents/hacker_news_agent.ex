defmodule Oracle.Agents.HackerNewsAgent do
  use Oracle.Agents.Base

  @api_url "http://hn.algolia.com/api/v1/search_by_date"

  def start_link(opts) do
    category = Keyword.fetch!(opts, :category)
    name = {:via, Registry, {Oracle.AgentRegistry, {__MODULE__, category}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl Oracle.Engine.PollingAgent
  def fetch(%{category: category} = _state) do
    # Poll stories from the last 15 minutes
    since = System.os_time(:second) - 900

    params = %{
      "query" => query_for_category(category),
      "tags" => "story",
      "numericFilters" => "created_at_i>#{since}",
      "hitsPerPage" => "50"
    }

    case Oracle.HTTP.get(@api_url, params: params) do
      {:ok, %{"hits" => hits}} -> parse_response(hits)
      {:ok, _body} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Oracle.Engine.PollingAgent
  def relevance_context(signal) do
    signal.title
  end

  @impl Oracle.Engine.PollingAgent
  def poll_interval do
    :timer.minutes(10)
  end

  defp parse_response(hits) do
    signals =
      hits
      |> Enum.filter(fn hit -> hit["title"] && hit["title"] != "" end)
      |> Enum.map(fn hit ->
        url = hit["url"] || "https://news.ycombinator.com/item?id=#{hit["objectID"]}"

        %{
          source: :hacker_news,
          source_url: url,
          title: hit["title"],
          content: hit["title"]
        }
      end)

    {:ok, signals}
  end

  # Algolia uses AND by default — no boolean OR support.
  # Use broad single terms that capture the category well on HN.
  defp query_for_category(:finance), do: "economy"
  defp query_for_category(:politics), do: "election"
  defp query_for_category(:crypto), do: "crypto"
  defp query_for_category(:sports), do: "sports"
  defp query_for_category(:science), do: "research"
  defp query_for_category(:tech), do: "AI"
end
