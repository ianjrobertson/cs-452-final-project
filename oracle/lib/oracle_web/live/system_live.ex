defmodule OracleWeb.SystemLive do
  use OracleWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(5000, :refresh)

    {:ok,
     socket
     |> assign(:agents, list_agents())
     |> assign(:page_title, "System")}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, :agents, list_agents())}
  end

  defp list_agents do
    top_level_agents() ++ global_agents() ++ dynamic_agents()
  end

  defp top_level_agents do
    # Agents started directly under Oracle.Supervisor (e.g. PolymarketAgent)
    children =
      try do
        Supervisor.which_children(Oracle.Supervisor)
      rescue
        _ -> []
      end

    children
    |> Enum.filter(fn {id, _pid, _type, modules} ->
      is_agent_module?(id, modules)
    end)
    |> Enum.map(fn {id, pid, _type, modules} ->
      name = module_name(id, modules)

      %{
        name: name,
        type: :global,
        status: if(is_pid(pid) and Process.alive?(pid), do: :running, else: :stopped)
      }
    end)
  end

  defp global_agents do
    children =
      try do
        Supervisor.which_children(Oracle.Agents.GlobalSupervisor)
      rescue
        _ -> []
      end

    Enum.map(children, fn {id, pid, _type, modules} ->
      %{
        name: module_name(id, modules),
        type: :global,
        status: if(is_pid(pid) and Process.alive?(pid), do: :running, else: :stopped)
      }
    end)
  end

  defp dynamic_agents do
    # Get all registered agents from the Registry
    registered =
      try do
        Registry.select(Oracle.AgentRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
      rescue
        _ -> []
      end

    Enum.map(registered, fn {{module, key}, pid} ->
      short_module = module |> Module.split() |> List.last()

      %{
        name: "#{short_module} [#{inspect(key)}]",
        type: :dynamic,
        status: if(is_pid(pid) and Process.alive?(pid), do: :running, else: :stopped)
      }
    end)
  end

  defp is_agent_module?(id, modules) do
    name = to_string(id) <> inspect(modules)
    String.contains?(name, "Agent")
  end

  defp module_name(id, modules) do
    cond do
      is_atom(id) and String.contains?(to_string(id), "Agent") ->
        id |> Module.split() |> List.last()

      is_list(modules) and modules != [] ->
        hd(modules) |> Module.split() |> List.last()

      true ->
        inspect(id)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 class="text-2xl font-bold font-mono mb-6 text-primary">System Status</h1>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <div class="bg-base-200 rounded-lg p-4">
          <h2 class="text-sm font-bold font-mono text-base-content/70 mb-4 uppercase">Global Agents</h2>
          <div class="space-y-2">
            <div :for={agent <- Enum.filter(@agents, &(&1.type == :global))}
                 class="flex items-center justify-between p-2 rounded bg-base-300">
              <span class="font-mono text-sm">{agent.name}</span>
              <span class={["badge badge-sm font-mono", status_badge(agent.status)]}>
                {agent.status}
              </span>
            </div>
            <p :if={Enum.filter(@agents, &(&1.type == :global)) == []}
               class="text-base-content/40 font-mono text-sm text-center py-4">
              No global agents running
            </p>
          </div>
        </div>

        <div class="bg-base-200 rounded-lg p-4">
          <h2 class="text-sm font-bold font-mono text-base-content/70 mb-4 uppercase">Dynamic Agents</h2>
          <div class="space-y-2">
            <div :for={agent <- Enum.filter(@agents, &(&1.type == :dynamic))}
                 class="flex items-center justify-between p-2 rounded bg-base-300">
              <span class="font-mono text-sm truncate mr-2">{agent.name}</span>
              <span class={["badge badge-sm font-mono", status_badge(agent.status)]}>
                {agent.status}
              </span>
            </div>
            <p :if={Enum.filter(@agents, &(&1.type == :dynamic)) == []}
               class="text-base-content/40 font-mono text-sm text-center py-4">
              No dynamic agents running
            </p>
          </div>
        </div>
      </div>

      <div class="mt-4 text-xs text-base-content/30 font-mono">
        Auto-refreshes every 5 seconds
      </div>
    </div>
    """
  end

  defp status_badge(:running), do: "badge-success"
  defp status_badge(:stopped), do: "badge-error"
  defp status_badge(_), do: "badge-ghost"
end
