defmodule Oracle.Repo.Migrations.CreateSignals do
  use Ecto.Migration

  def change do
    create table(:signals) do
      add :source, :string, null: false        # "news" | "reddit" | "economic"
      add :source_url, :string
      add :title, :text
      add :content, :text, null: false
      add :embedding, :vector, size: 1536

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:signals, [:market_id])
    create index(:signals, [:market_id, :relevance_score])
  end
end
