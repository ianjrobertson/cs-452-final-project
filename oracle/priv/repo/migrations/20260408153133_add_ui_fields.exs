defmodule Oracle.Repo.Migrations.AddUiFields do
  use Ecto.Migration

  def change do
    alter table(:briefs) do
      add :title, :string
    end

    alter table(:markets) do
      add :description, :text
      add :image_url, :string
      add :volume, :float
    end
  end
end
