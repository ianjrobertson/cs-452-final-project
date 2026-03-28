defmodule Oracle.Markets do
  import Ecto.Query
  alias Ecto.Multi
  alias Oracle.Repo
  alias Oracle.Markets.Market
  alias Oracle.Markets.UserSubscription
  alias Oracle.Markets.ProbabilityHistory

  def upsert(attrs) do
    %Market{}
    |> Market.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:probability, :active, :updated_at]},
      conflict_target: :condition_id
    )
  end

  def get_by_condition_id(condition_id) do
    Repo.get_by(Market, condition_id: condition_id)
  end

  def list_active() do
    Market
    |> where([m], m.active == true)
    |> order_by([m], desc: m.inserted_at)
    |> Repo.all()
  end

  def subscribe(user, market) do
    Multi.new()
    |> Multi.insert(:subscription, UserSubscription.changeset(%UserSubscription{}, %{
      user_id: user.id,
      market_id: market.id
    }))
    |> Repo.transaction()
  end

  def unsubscribe(user, market) do
    case Repo.get_by(UserSubscription, user_id: user.id, market_id: market.id) do
      nil -> {:error, :not_found}
      sub -> Repo.delete(sub)
    end
  end

  def list_markets_for_user(user_id) do
    Market
    |> join(:inner, [m], s in UserSubscription, on: s.market_id == m.id and s.user_id == ^user_id)
    |> order_by([m], desc: m.inserted_at)
    |> Repo.all()
  end

  def record_probability(market_id, probability) do
    Repo.insert_all(ProbabilityHistory, [%{
      market_id: market_id,
      probability: probability,
      recorded_at: DateTime.utc_now(:second)
    }])
  end

  def probability_history_for(market_id) do
    ProbabilityHistory
    |> where([p], p.market_id == ^market_id)
    |> order_by([p], asc: p.recorded_at)
    |> Repo.all()
  end

end
