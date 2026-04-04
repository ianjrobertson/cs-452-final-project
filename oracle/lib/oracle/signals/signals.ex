defmodule Oracle.Signals do
  import Ecto.Query
  alias Oracle.Repo
  alias Oracle.Signals.Signal
  alias Oracle.Signals.MarketSignal

  def insert(signal_attrs, market_scores) do
    {:ok, signal} = %Signal{}
    |> Signal.changeset(signal_attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :source_url, returning: true)

    Enum.each(market_scores, fn {market_id, score} ->
      %MarketSignal{}
      |> MarketSignal.changeset(%{signal_id: signal.id, market_id: market_id, relevance_score: score})
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:market_id, :signal_id])
    end)
  end

  def top_for_market(market_id, limit \\ 30) do
    from s in Signal,
      join: ms in MarketSignal, on: ms.signal_id == s.id,
      where: ms.market_id == ^market_id and ms.relevance_score > 0.6,
      order_by: [desc: s.inserted_at],
      limit: ^limit
    |> Repo.all()
  end

  def count_since(market_id, datetime) do
    from s in Signal,
      join: ms in MarketSignal, on: ms.signal_id == s.id,
      where: ms.market_id == ^market_id and s.inserted_at > ^datetime
    |> Repo.aggregate(:count)
  end


end
