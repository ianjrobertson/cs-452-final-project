defmodule Oracle.Agents.DynamicAgents do
  def start_agent(module, opts) do
    DynamicSupervisor.start_child(Oracle.Agents.DynamicSupervisor, {module, opts})
  end

  def stop_agent(module, key) do
    case Registry.lookup(Oracle.AgentRegistry, {module, key}) do
      [{pid, _}] = DynamicSupervisor.terminate_child(Oracle.Agents.DynamicSupervisor, pid),
      [] -> {:error, :not_found}
    end
  end

  def agent_running?(module, key) do
    Registry.lookup(Oracle.AgentRegistry, {module, key}) != []
  end
end
