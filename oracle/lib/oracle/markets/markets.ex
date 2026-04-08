defmodule Oracle.Markets do
  import Ecto.Query
  alias Oracle.Repo
  alias Oracle.Markets.Market
  alias Oracle.Markets.UserSubscription
  alias Oracle.Markets.ProbabilityHistory
  alias Oracle.Engine.Embeddings

  def upsert(attrs) do
    %Market{}
    |> Market.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:probability, :active, :updated_at, :end_date, :description, :image_url, :volume]},
      conflict_target: :condition_id
    )
  end

  def get_by_condition_id(condition_id) do
    Repo.get_by(Market, condition_id: condition_id)
  end

  def set_question_embedding(market, embedding) do
    market
    |> Ecto.Changeset.change(question_embedding: embedding)
    |> Repo.update()
  end

  def list_active() do
    Market
    |> where([m], m.active)
    |> order_by([m], desc: m.inserted_at)
    |> Repo.all()
  end

  def subscribe(user, market) do
    with {:ok, sub} <- insert_subscription(user, market),
         {:ok, market} <- ensure_question_embedding(market),
         {:ok, market} <- ensure_category(market) do
      spawn_market_agents(market)
      {:ok, sub}
    end
  end

  defp insert_subscription(user, market) do
    %UserSubscription{}
    |> UserSubscription.changeset(%{user_id: user.id, market_id: market.id})
    |> Repo.insert()
  end

  defp spawn_market_agents(market) do
    alias Oracle.Agents.DynamicAgents
    alias Oracle.Agents.DynamicAgents
    alias Oracle.Agents.GdeltAgent
    #alias Oracle.Agents.HackerNewsAgent
    alias Oracle.Agents.SynthesisAgent

    category = String.to_existing_atom(market.category)

    unless DynamicAgents.agent_running?(SynthesisAgent, market.id) do
      DynamicAgents.start_agent(SynthesisAgent, market_id: market.id)
    end

    unless DynamicAgents.agent_running?(GdeltAgent, category) do
      DynamicAgents.start_agent(GdeltAgent, category: category)
    end

    # unless DynamicAgents.agent_running?(HackerNewsAgent, category) do
    #   DynamicAgents.start_agent(HackerNewsAgent, category: category)
    # end
  end

  def unsubscribe(user, market) do
    case Repo.get_by(UserSubscription, user_id: user.id, market_id: market.id) do
      nil ->
        {:error, :not_found}

      sub ->
        Repo.delete(sub)
        if subscriber_count(market.id) == 0, do: stop_market_agents(market)
    end
  end

  defp stop_market_agents(market) do
    alias Oracle.Agents.DynamicAgents
    alias Oracle.Agents.GdeltAgent
    alias Oracle.Agents.HackerNewsAgent
    alias Oracle.Agents.SynthesisAgent

    DynamicAgents.stop_agent(SynthesisAgent, market.id)

    if market.category do
      category = String.to_existing_atom(market.category)

      unless markets_in_category?(category) do
        DynamicAgents.stop_agent(GdeltAgent, category)
        DynamicAgents.stop_agent(HackerNewsAgent, category)
      end
    end
  end

  def list_markets_for_user(user_id) do
    Market
    |> join(:inner, [m], s in UserSubscription, on: s.market_id == m.id and s.user_id == ^user_id)
    |> order_by([m], desc: m.inserted_at)
    |> Repo.all()
  end

  def record_probability(market_id, probability) do
    Repo.insert_all(ProbabilityHistory, [
      %{
        market_id: market_id,
        probability: probability,
        recorded_at: DateTime.utc_now(:second)
      }
    ])
  end

  def probability_history_for(market_id) do
    ProbabilityHistory
    |> where([p], p.market_id == ^market_id)
    |> order_by([p], asc: p.recorded_at)
    |> Repo.all()
  end

  defp ensure_category(market) do
    case market.category do
      nil ->
        category = Oracle.Engine.Categories.classify(market.question_embedding)

        market
        |> Ecto.Changeset.change(category: Atom.to_string(category))
        |> Repo.update()

      _existing ->
        {:ok, market}
    end
  end

  defp markets_in_category?(category) do
    Market
    |> join(:inner, [m], s in UserSubscription, on: s.market_id == m.id)
    |> where([m], m.category == ^Atom.to_string(category))
    |> Repo.exists?()
  end

  defp ensure_question_embedding(market) do
    case market.question_embedding do
      nil ->
        with {:ok, embedding} <- Embeddings.embed(market.question) do
          set_question_embedding(market, embedding)
        end

      _existing ->
        {:ok, market}
    end
  end

  defp subscriber_count(market_id) do
    UserSubscription
    |> where([u], u.market_id == ^market_id)
    |> Repo.aggregate(:count)
  end

  def get!(id), do: Repo.get!(Market, id)

  def subscribed?(user_id, market_id) do
    UserSubscription
    |> where([s], s.user_id == ^user_id and s.market_id == ^market_id)
    |> Repo.exists?()
  end

  def list_categories do
    Market
    |> where([m], m.active and not is_nil(m.category))
    |> select([m], m.category)
    |> distinct(true)
    |> Repo.all()
  end

  def active_market_embeddings() do
    Market
    |> join(:inner, [m], s in UserSubscription, on: s.market_id == m.id)
    |> where([m], not is_nil(m.question_embedding))
    |> distinct([m], m.id)
    |> Repo.all()
  end
end
