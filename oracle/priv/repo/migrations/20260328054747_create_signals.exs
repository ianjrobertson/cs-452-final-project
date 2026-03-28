defmodule Oracle.Repo.Migrations.CreateSignals do
  use Ecto.Migration

  def change do
    create table(:signals) do
      add :market_id, references(:markets, on_delete: :delete_all), null: false
      add :source, :string, null: false        # "news" | "reddit" | "economic" | "x"
      add :source_url, :string
      add :title, :text
      add :content, :text, null: false
      add :embedding, :vector, size: 1536
      add :relevance_score, :float, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:signals, [:market_id])
    create index(:signals, [:market_id, :relevance_score])
  end
end
