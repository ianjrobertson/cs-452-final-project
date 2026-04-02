defmodule Oracle.Markets.PolymarketClient do
  @api_url "https://gamma-api.polymarket.com/markets"
  def list_active_markets(opts \\ []) do
    case Oracle.HTTP.get("#{@api_url}", params: %{active: true, limit: 50}) do
      {:ok, body} ->
        {:ok, Enum.map(body, &normalize/1)}
      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_market(condition_id) do
    case Oracle.HTTP.get("#{@api_url}/#{condition_id}") do
      {:ok, body} ->
        {:ok, normalize(body)}
      {:error, reason} ->
        {:error, reason}
    end
  end

  # See the polymarket API docs for what gets returned. We might want description in the future as well. 
  defp normalize(market) do
    %{
      condition_id: market["conditionId"],
      question: market["question"],
      active: market["active"],
      probability: parse_probability(market["outcomePrices"]),
      end_date: parse_end_date(market["endDateIso"])
    }
  end

  defp parse_probability(nil), do: nil
  defp parse_probability(outcome_prices) do
    [yes_price | _rest] = Jason.decode!(outcome_prices)
    String.to_float(yes_price)
  end

  defp parse_end_date(nil), do: nil
  defp parse_end_date(end_date) do
    DateTime.from_iso8601!(end_date)
    |> DateTime.truncate(:second)
  end

end
