defmodule Oracle.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      OracleWeb.Telemetry,
      Oracle.Repo,
      {DNSCluster, query: Application.get_env(:oracle, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Oracle.PubSub},
      # Start a worker by calling: Oracle.Worker.start_link(arg)
      # {Oracle.Worker, arg},
      # Start to serve requests, typically the last entry
    ] ++ maybe_children() ++ [
      OracleWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Oracle.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    OracleWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp maybe_children do
    if Application.get_env(:oracle, :start_polymarket_agent, true),
    do: [Oracle.Agents.PolymarketAgent],
    else: []
  end
end
