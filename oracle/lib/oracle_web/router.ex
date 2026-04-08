defmodule OracleWeb.Router do
  use OracleWeb, :router

  import OracleWeb.UsersAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {OracleWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_users
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", OracleWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:oracle, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: OracleWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", OracleWeb do
    pipe_through [:browser, :require_authenticated_users]

    live_session :require_authenticated_users,
      on_mount: [{OracleWeb.UsersAuth, :require_authenticated}] do
      live "/users/settings", UsersLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UsersLive.Settings, :confirm_email

      live "/dashboard", DashboardLive, :index
      live "/markets", MarketsLive.Index, :index
      live "/markets/:id", MarketsLive.Show, :show
      live "/briefs", BriefsLive.Index, :index
      live "/signals", SignalsLive.Index, :index
      live "/system", SystemLive, :index
    end

    post "/users/update-password", UsersSessionController, :update_password
  end

  scope "/", OracleWeb do
    pipe_through [:browser]

    live_session :current_users,
      on_mount: [{OracleWeb.UsersAuth, :mount_current_scope}] do
      live "/users/register", UsersLive.Registration, :new
      live "/users/log-in", UsersLive.Login, :new
      live "/users/log-in/:token", UsersLive.Confirmation, :new
    end

    post "/users/log-in", UsersSessionController, :create
    delete "/users/log-out", UsersSessionController, :delete
  end
end
