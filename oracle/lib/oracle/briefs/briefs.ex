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

  def list_for_user(user_id) do
    Brief
    |> join(:inner, [b], m in Oracle.Markets.Market, on: b.market_id == m.id)
    |> join(:inner, [b, m], s in Oracle.Markets.UserSubscription,
      on: s.market_id == m.id and s.user_id == ^user_id
    )
    |> order_by([b], desc: b.inserted_at)
    |> preload(:market)
    |> Repo.all()
  end
end
