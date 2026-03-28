defmodule Oracle.Repo.Migrations.CreateMarkets do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS vector"

    create table(:markets) do
      add :condition_id, :string, null: false
      add :question, :test, null: false
      add :question_embedding, :vector, size: 1536
      add :probability, :float
      add :end_date, :utc_datetime
      add :active, :boolean, default: true, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:markets, [:condition_id])
  end

  def down do
    drop table(:markets)
    execute "DROP EXTENSION IF EXISTS vector"
  end
end
