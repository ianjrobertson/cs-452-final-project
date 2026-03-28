defmodule Oracle.Signals do
  import Ecto.Query
  alias Oracle.Repo
  alias Oracle.Signals.Signal

  def insert(attrs) do
    %Signal{}
    |> Signal.changeset(attrs)
    |> Repo.insert()
  end

  def top_for_market(market_id, limit \\ 30) do
    Signal
    |> where([s], s.market_id == ^market_id and s.relevance_score > 0.6)
    |> order_by([s], desc: s.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def count_since(market_id, datetime) do
    Signal
    |> where([s], s.market_id == ^market_id and s.inserted_at > ^datetime)
    |> Repo.aggregate(:count)
  end


end
