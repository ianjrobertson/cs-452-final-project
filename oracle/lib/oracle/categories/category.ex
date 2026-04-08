defmodule Oracle.Categories.Category do
  use Ecto.Schema
  import Ecto.Changeset

  schema "categories" do
    field :name, :string
    field :embedding, Pgvector.Ecto.Vector

    timestamps(type: :utc_datetime)
  end

  def changeset(category, attrs) do
    category
    |> cast(attrs, [:name, :embedding])
    |> validate_required([:name, :embedding])
    |> unique_constraint(:name)
  end
end
