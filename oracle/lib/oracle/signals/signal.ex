defmodule Oracle.Signals.Signal do
  use Ecto.Schema
  import Ecto.Changeset

  @sources ~w(news reddit economic)a

  schema "signals" do
    belongs_to :market, Oracle.Markets.Market

    field :source, Ecto.Enum, values: @sources
    field :source_url, :string
    field :title, :string
    field :content, :string
    field :embedding, Pgvector.Ecto.Vector
    field :relevance_score, :float

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(signal, attrs) do
    signal
    |> cast(attrs, [:market_id, :source, :source_url, :title, :content, :relevance_score])
    |> validate_required([:market_id, :source, :content, :relevance_score])
    |> validate_inclusion(:source, @sources)
    |> validate_number(:relevance_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> assoc_constraint(:market)
  end
end
