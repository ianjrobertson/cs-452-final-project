defmodule Oracle.Briefs do
  import Ecto.Query
  alias Oracle.Repo
  alias Oracle.Briefs.Brief

  def insert(attrs) do
    %Brief{}
    |> Brief.changeset(attrs)
    |> Repo.insert()
  end

  def latest_for_market(market_id) do
    Brief
    |> where([b], b.market_id == ^market_id)
    |> order_by([b], desc: b.inserted_at)
    |> limit(1)
    |> Repo.one()

  end

  def list_for_market(market_id) do
    Brief
    |> where([b], b.market_id == ^market_id)
    |> order_by([b], desc: b.inserted_at)
    |> Repo.all()
  end
end
