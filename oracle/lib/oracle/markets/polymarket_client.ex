defmodule Oracle.Markets.PolymarketClient do
  def list_active_markets(opts \\ []) do
    ## hit the polymarket gamma api to get a list of markets
    ## return a list of markets. This is what we list for the user to select
  end

  def get_market(condition_id) do
    ## given a specific market, get more information
    ## This is the data we store in the Market database record.
  end

  defp normalize(market) do
    # Turn the raw json into a struct
  end

end
