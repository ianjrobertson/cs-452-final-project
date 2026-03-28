defmodule Oracle.Markets.ProbabilityHistory do
  use Ecto.Schema
  import Ecto.Changeset

  schema "probability_history" do
    belongs_to :market, Oracle.Markets.Market

    field :probability, :float
    field :recorded_at, :utc_datetime
  end

  def changeset(history, attrs) do
    history
    |> cast(attrs, [:market_id, :probability, :recorded_at])
    |> validate_required([:market_id, :probability, :recorded_at])
    |> validate_number(:probability, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> assoc_constraint(:market)
  end
end
