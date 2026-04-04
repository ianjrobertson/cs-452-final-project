defmodule Oracle.Repo.Migrations.CreateMarketSignals do
  use Ecto.Migration

  def change do
    create table(:market_signals, primary_key: false) do
      add :market_id, references(:markets, on_delete: :delete_all), null: false
      add :signal_id, references(:signals, on_delete: :delete_all), null: false
      add :relevance_score, :float, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:market_signals, [:market_id, :signal_id])
    create index(:market_signals, [:market_id, :relevance_score])

    drop index(:signals, [:market_id])
    drop index(:signals, [:market_id, :relevance_score])

    alter table(:signals) do
      remove :market_id
      remove :relevance_score
    end
  end
end
