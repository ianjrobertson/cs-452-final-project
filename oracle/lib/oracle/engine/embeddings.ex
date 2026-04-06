defmodule Oracle.Engine.Embeddings do
  alias Oracle.HTTP
  alias Oracle.Markets.Market
  alias Oracle.Signals.Signal
  @open_ai_api "https://api.openai.com/v1/embeddings"

  def embed(text) do
    case embed_batch([text]) do
      {:ok, [embedding]} -> {:ok, embedding}
      error -> error
    end
  end

  def embed_batch(texts) do
    body = %{input: texts, model: "text-embedding-3-small", encoding_format: "float"}
    headers = [{"authorization", "Bearer #{Application.fetch_env!(:oracle, :openai_api_key)}"}]

    case Oracle.HTTP.post(@open_ai_api, body, headers: headers) do
      {:ok, %{"data" => entries}} ->
        embeddings = Enum.map(entries, fn entry -> entry["embedding"] end)
        {:ok, embeddings}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def cosine_similarity(vec_a, vec_b) do
    dot = Enum.zip(vec_a, vec_b) |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
    mag_a = :math.sqrt(Enum.reduce(vec_a, 0.0, fn x, acc -> acc + x * x end))
    mag_b = :math.sqrt(Enum.reduce(vec_b, 0.0, fn x, acc -> acc + x * x end))
    dot / (mag_a * mag_b)
  end

  # takes a list Signals, and a list of Markets
  def score_against_markets(signals, markets) do
    for signal <- signals,
        market <- markets,
        score = cosine_similarity(signal, market.question_embedding),
        score > 0.40 do
      {signal.id, market.id, score}
    end
  end
end
