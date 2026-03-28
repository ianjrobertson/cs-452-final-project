defmodule Oracle.Briefs.Brief do
  use Ecto.Schema
  import Ecto.Changeset

  schema "briefs" do
    belongs_to :market, Oracle.Markets.Market

    field :content, :string
    field :key_signals, :map
    field :probability_at_generation, :float

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(brief, attrs) do
    brief
    |> cast(attrs, [:market_id, :content, :key_signals, :probability_at_generation])
    |> validate_required([:market_id, :content])
  end

end
