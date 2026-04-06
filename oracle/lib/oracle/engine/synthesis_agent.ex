defmodule Oracle.Engine.SynthesisAgent do
  @callback build_prompt(market_context :: map(), signal_context :: list(map())) :: String.t()
  @callback parse_response(response :: String.t()) :: map()
  @callback synthesis_threshold() :: pos_integer()
end
