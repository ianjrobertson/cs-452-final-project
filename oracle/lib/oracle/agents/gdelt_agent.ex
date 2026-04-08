defmodule Oracle.Agents.GdeltAgent do
  use Oracle.Agents.Base
  @api_url "https://api.gdeltproject.org/api/v2/doc/doc"

  def start_link(opts) do
    category = Keyword.fetch!(opts, :category)
    name = {:via, Registry, {Oracle.AgentRegistry, {__MODULE__, category}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl Oracle.Engine.PollingAgent
  def fetch(%{category: category} = _state) do
    params = %{
      "query" => "#{query_for_category(category)} sourcelang:english",
      "mode" => "artlist",
      "format" => "json",
      "maxrecords" => "250",
      "timespan" => "60min"
    }

    case Oracle.HTTP.get(@api_url, params: params) do
      {:ok, %{"articles" => articles}} -> parse_response(articles)
      {:ok, _body} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Oracle.Engine.PollingAgent
  def relevance_context(signal) do
    signal.title
  end

  @impl Oracle.Engine.PollingAgent
  def poll_interval() do
    :timer.minutes(15)
  end

  defp parse_response(articles) do
    {:ok,
     Enum.map(articles, fn article ->
       %{
         source: :news,
         source_url: article["url"],
         title: article["title"],
         content: article["title"]
       }
     end)}
  end

  # hardcoded search terms
  # In the future make these dynamic based on cosine similarity. Could use the same engine as dynamic subreddits
  defp query_for_category(:finance), do: "(economy OR markets OR inflation OR trade)"
  defp query_for_category(:politics), do: "(election OR congress OR legislation OR sanctions)"
end
