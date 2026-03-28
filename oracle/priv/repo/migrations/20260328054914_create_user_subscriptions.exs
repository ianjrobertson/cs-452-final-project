defmodule Oracle.Repo.Migrations.CreateUserSubscriptions do
  use Ecto.Migration

  def change do
    create table(:user_subscriptions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :market_id, references(:markets, on_delete: :delete_all), null: false
      add :alert_threshold, :float, default: 0.10  # notify when prob moves by this much

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_subscriptions, [:user_id, :market_id])
    create index(:user_subscriptions, [:market_id])
  end
end
