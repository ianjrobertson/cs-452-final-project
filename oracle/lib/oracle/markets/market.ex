defmodule Oracle.Markets.Market do
  use Ecto.Schema
  import Ecto.Changeset

  schema "markets" do
    field :condition_id, :string
    field :question, :string
    field :question_embedding, Pgvector.Ecto.Vector
    field :probability, :float
    field :end_date, :utc_datetime
    field :active, :boolean, default: true

    has_many :signals, Oracle.Signals.Signal
    has_many :briefs, Oracle.Briefs.Brief
    has_many :probability_history, Oracle.Markets.ProbabilityHistory
    has_many :user_subscriptions, Oracle.Markets.UserSubscription

    timestamps(type: :utc_datetime)
  end

  def changeset(market, attrs) do
    market
    |> cast(attrs, [:question, :condition_id, :probability, :active])
    |> validate_required([:question, :condition_id])
    |> unique_constraint(:condition_id)
  end
end
