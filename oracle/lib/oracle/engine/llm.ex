defmodule Oracle.Engine.LLM do
  @openai_chat_api "https://api.openai.com/v1/chat/completions"

  def chat(system_prompt, user_prompt, opts \\ []) do
    model = Keyword.get(opts, :model, "gpt-4o-mini")

    body = %{
      model: model,
      messages: [
        %{role: "system", content: system_prompt},
        %{role: "user", content: user_prompt}
      ],
      temperature: 0.7
    }

    headers = [{"authorization", "Bearer #{Application.fetch_env!(:oracle, :openai_api_key)}"}]

    case Oracle.HTTP.post(@openai_chat_api, body, headers: headers) do
      {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]}} ->
        {:ok, content}

      {:ok, unexpected} ->
        {:error, {:unexpected_response, unexpected}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
