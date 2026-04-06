defmodule Oracle.Agents.DynamicAgents do
  start_agent(module, opts) do
    DynamicSupervisor.start_child(Oracle.D)
  end

  stop_agent(module, key) do

  end

  agent_running?(module, key) do

  end
end
