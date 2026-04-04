defmodule Oracle.Signals.MarketSignal do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "market_signals" do
    belongs_to :market, Oracle.Markets.Market
    belongs_to :signal, Oracle.Signals.Signal

    field :relevance_score, :float
    timestamps(type: :utc_datetime)
  end

  def changeset(market_signal, attrs) do
    market_signal
    |> cast(attrs, [:market_id, :signal_id, :relevance_score])
    |> validate_required([:market_id, :signal_id, :relevance_score])
    |> validate_number(:relevance_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> assoc_constraint(:market)
    |> assoc_constraint(:signal)
  end
end
