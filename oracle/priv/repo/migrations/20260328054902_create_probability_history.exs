defmodule Oracle.Repo.Migrations.CreateProbabilityHistory do
  use Ecto.Migration

  def change do
    create table(:probability_history) do
      add :market_id, references(:markets, on_delete: :delete_all), null: false
      add :probability, :float, null: false
      add :recorded_at, :utc_datetime, null: false
    end

    create index(:probability_history, [:market_id, :recorded_at])
  end
end
