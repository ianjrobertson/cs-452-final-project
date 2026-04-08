defmodule Oracle.Repo.Migrations.AddUniqueIndexOnSignalsSourceUrl do
  use Ecto.Migration

  def change do
    create unique_index(:signals, [:source_url])
  end
end
