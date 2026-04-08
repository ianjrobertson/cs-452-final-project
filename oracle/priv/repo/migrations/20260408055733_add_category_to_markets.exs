defmodule Oracle.Repo.Migrations.AddCategoryToMarkets do
  use Ecto.Migration

  def change do
    alter table(:markets) do
      add :category, :string
    end
  end
end
