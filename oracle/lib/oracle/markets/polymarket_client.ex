defmodule Oracle.Markets.PolymarketClient do
  @api_url "https://gamma-api.polymarket.com/markets"
  @page_size 100
  @max_pages 5

  def list_active_markets(_opts \\ []) do
    end_date_min = Date.utc_today() |> Date.to_iso8601()
    fetch_all_pages(end_date_min, 0, [], 0)
  end

  defp fetch_all_pages(_end_date_min, _offset, acc, page) when page >= @max_pages, do: {:ok, acc}

  defp fetch_all_pages(end_date_min, offset, acc, page) do
    params = %{
      active: true,
      limit: @page_size,
      offset: offset,
      end_date_min: end_date_min
    }

    case Oracle.HTTP.get(@api_url, params: params) do
      {:ok, []} ->
        {:ok, acc}

      {:ok, body} when is_list(body) ->
        markets = Enum.map(body, &normalize/1)

        if length(body) < @page_size do
          {:ok, acc ++ markets}
        else
          fetch_all_pages(end_date_min, offset + @page_size, acc ++ markets, page + 1)
        end

      {:ok, _body} ->
        {:ok, acc}

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
    {value, _} = Float.parse(yes_price)
    value
  end

  defp parse_end_date(nil), do: nil
  defp parse_end_date(end_date) do
    {:ok, datetime} = end_date
      |> Date.from_iso8601!()
      |> DateTime.new(~T[00:00:00], "Etc/UTC")
    datetime
  end

end
