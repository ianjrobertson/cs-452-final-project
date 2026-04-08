defmodule OracleWeb.PageController do
  use OracleWeb, :controller

  def home(conn, _params) do
    if conn.assigns[:current_scope] && conn.assigns.current_scope.users do
      redirect(conn, to: ~p"/dashboard")
    else
      redirect(conn, to: ~p"/users/log-in")
    end
  end
end
