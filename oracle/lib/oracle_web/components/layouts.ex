defmodule OracleWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use OracleWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-300">
      <aside class="w-56 bg-base-200 border-r border-base-300 flex flex-col">
        <div class="p-4 border-b border-base-300">
          <h1 class="text-lg font-bold font-mono tracking-wider text-primary">ORACLE</h1>
          <p class="text-xs text-base-content/50 font-mono">Market Intelligence</p>
        </div>
        <ul class="menu menu-sm flex-1 p-2 font-mono">
          <li><.link navigate={~p"/dashboard"}><.icon name="hero-squares-2x2" class="size-4" /> Dashboard</.link></li>
          <li><.link navigate={~p"/markets"}><.icon name="hero-chart-bar" class="size-4" /> Markets</.link></li>
          <li><.link navigate={~p"/briefs"}><.icon name="hero-document-text" class="size-4" /> Briefs</.link></li>
          <li><.link navigate={~p"/signals"}><.icon name="hero-bolt" class="size-4" /> Signals</.link></li>
          <li><.link navigate={~p"/system"}><.icon name="hero-cpu-chip" class="size-4" /> System</.link></li>
        </ul>
        <div :if={@current_scope} class="border-t border-base-300 p-2">
          <ul class="menu menu-sm font-mono text-xs text-base-content/60">
            <li class="menu-title truncate">{@current_scope.users.email}</li>
            <li><.link href={~p"/users/settings"}>Settings</.link></li>
            <li><.link href={~p"/users/log-out"} method="delete">Log out</.link></li>
          </ul>
        </div>
      </aside>
      <main class="flex-1 overflow-auto p-6">
        {render_slot(@inner_block)}
      </main>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="join rounded-full bg-base-300">
      <button
        class="join-item btn btn-xs btn-ghost"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4" />
      </button>

      <button
        class="join-item btn btn-xs btn-ghost"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4" />
      </button>

      <button
        class="join-item btn btn-xs btn-ghost"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4" />
      </button>
    </div>
    """
  end
end
