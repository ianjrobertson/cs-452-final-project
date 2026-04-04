defmodule Oracle.Signals.Signal do
  use Ecto.Schema
  import Ecto.Changeset

  @sources ~w(news reddit economic)a

  schema "signals" do
    many_to_many :markets, Oracle.Markets.Market, join_through: "market_signals"

    field :source, Ecto.Enum, values: @sources
    field :source_url, :string
    field :title, :string
    field :content, :string
    field :embedding, Pgvector.Ecto.Vector

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(signal, attrs) do
    signal
    |> cast(attrs, [:source, :source_url, :title, :content, :embedding])
    |> validate_required([:source, :content])
    |> unique_constraint(:source_url)
  end
end
