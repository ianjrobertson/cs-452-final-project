defmodule Oracle.Repo.Migrations.CreateBriefs do
  use Ecto.Migration

  def change do
    create table(:briefs) do
      add :market_id, references(:markets, on_delete: :delete_all), null: false
      add :content, :text, null: false
      add :key_signals, :map                   # JSONB — array of {title, source, score}
      add :probability_at_generation, :float   # snapshot of market prob when brief was made

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:briefs, [:market_id])
  end
end
