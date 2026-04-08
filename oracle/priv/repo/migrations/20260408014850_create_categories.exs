defmodule Oracle.Repo.Migrations.CreateCategories do
  use Ecto.Migration

  def change do
    create table(:categories) do
      add :name, :string, null: false
      add :embedding, :vector, size: 1536, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:categories, [:name])
  end
end
