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
        <nav class="flex-1 p-2 space-y-1">
          <.nav_link href={~p"/dashboard"} icon="hero-squares-2x2" label="Dashboard" />
          <.nav_link href={~p"/markets"} icon="hero-chart-bar" label="Markets" />
          <.nav_link href={~p"/briefs"} icon="hero-document-text" label="Briefs" />
          <.nav_link href={~p"/signals"} icon="hero-bolt" label="Signals" />
          <.nav_link href={~p"/system"} icon="hero-cpu-chip" label="System" />
        </nav>
        <div :if={@current_scope} class="p-3 border-t border-base-300 text-xs text-base-content/60">
          <div class="font-mono truncate">{@current_scope.users.email}</div>
          <div class="mt-2 flex gap-2">
            <.link href={~p"/users/settings"} class="hover:text-base-content">Settings</.link>
            <.link href={~p"/users/log-out"} method="delete" class="hover:text-base-content">Log out</.link>
          </div>
        </div>
      </aside>
      <main class="flex-1 overflow-auto p-6">
        {render_slot(@inner_block)}
      </main>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link navigate={@href} class="flex items-center gap-3 px-3 py-2 rounded text-sm font-mono text-base-content/70 hover:text-base-content hover:bg-base-300 transition-colors">
      <.icon name={@icon} class="size-4" />
      {@label}
    </.link>
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
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
