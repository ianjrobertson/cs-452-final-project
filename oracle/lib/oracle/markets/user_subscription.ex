defmodule Oracle.Markets.UserSubscription do
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_subscriptions" do
    belongs_to :user, Oracle.Accounts.Users
    belongs_to :market, Oracle.Markets.Market

    field :alert_threshold, :float, default: 0.10

    timestamps(type: :utc_datetime)
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:user_id, :market_id, :alert_threshold])
    |> validate_required([:user_id, :market_id])
    |> validate_number(:alert_threshold, greater_than: 0.0, less_than_or_equal_to: 1.0)
    |> unique_constraint([:user_id, :market_id])
    |> assoc_constraint(:user)
    |> assoc_constraint(:market)
  end
end
