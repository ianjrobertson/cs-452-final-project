defmodule Oracle.HTTP do
  @max_attempts 4
  def get(url, opts \\ []) do
    headers = Keyword.get(opts, :headers, [])
    params = Keyword.get(opts, :params, %{})

    req = Req.new(url: url, headers: headers, params: params)
    do_get(req, 1, @max_attempts)
  end

  defp do_get(req, attempt, max) do
    do_request(req, &Req.get/1, attempt, max)
  end

  def post(url, body, opts) do
    headers = Keyword.get(opts, :headers, [])
    params = Keyword.get(opts, :params, %{})

    req = Req.new(url: url, headers: headers, params: params, json: body)
    do_post(req, 1, @max_attempts)
  end

  defp do_post(req, attempt, max) do
    do_request(req, &Req.post/1, attempt, max)
  end

  defp do_request(req, method, attempt, max) do
    case method.(req) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}
      {:ok, %{status: status}} when status in [429, 500, 502, 503, 504] and attempt < max ->
        Process.sleep(1000 * Integer.pow(2, attempt - 1))
        do_request(req, method, attempt+1, max)
      {:ok, %{status: status, body: _body}} ->
        {:error, {:http_error, status}}
      {:error, _exception} when attempt < max ->
        Process.sleep(1000 * Integer.pow(2, attempt - 1))
        do_request(req, method, attempt+1,  max)
      {:error, exception} ->
        {:error, {:http_exception, exception}}
    end
  end

  # TODO
  # def get_raw(url, opts) do

  # end
end
