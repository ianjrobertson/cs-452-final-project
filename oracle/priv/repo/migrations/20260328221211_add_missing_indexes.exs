defmodule Oracle.Repo.Migrations.AddMissingIndexes do
  use Ecto.Migration

  def change do
    create index(:signals, [:market_id, :inserted_at])
    create index(:briefs, [:market_id, :inserted_at])

    execute(
      "CREATE INDEX signals_embedding_idx ON signals USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)",
      "DROP INDEX IF EXISTS signals_embedding_idx"
    )
  end
end
