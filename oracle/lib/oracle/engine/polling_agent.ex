defmodule Oracle.Engine.PollingAgent do
  @callback fetch(state :: map()) :: {:ok, list(map())} | {:error, term()}
  @callback relevance_context(signal :: map()) :: String.t()
  @callback poll_interval() :: pos_integer()
end
