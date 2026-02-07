defmodule CriptoTrader.Binance.Client do
  @moduledoc false

  alias CriptoTrader.Config

  defstruct base_url: Config.binance_base_url(),
            api_key: Config.binance_api_key(),
            api_secret: Config.binance_api_secret(),
            recv_window: Config.binance_recv_window(),
            finch: CriptoTrader.Finch,
            receive_timeout: 15_000,
            request_fn: &Req.request/1

  @type t :: %__MODULE__{
          base_url: String.t(),
          api_key: String.t() | nil,
          api_secret: String.t() | nil,
          recv_window: non_neg_integer(),
          finch: atom(),
          receive_timeout: non_neg_integer(),
          request_fn: (keyword() -> {:ok, term()} | {:error, term()})
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct!(__MODULE__, opts)
  end

  @spec public_get(t(), String.t(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def public_get(%__MODULE__{} = client, path, params \\ %{}) do
    request(client, :get, path, params, [])
  end

  @spec signed_request(t(), atom(), String.t(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def signed_request(%__MODULE__{} = client, method, path, params \\ %{}) do
    with {:ok, client} <- require_credentials(client) do
      params
      |> normalize_params()
      |> add_timestamp(client.recv_window)
      |> sign_and_request(client, method, path)
    end
  end

  defp require_credentials(%__MODULE__{api_key: key, api_secret: secret} = client)
       when is_binary(key) and byte_size(key) > 0 and is_binary(secret) and byte_size(secret) > 0 do
    {:ok, client}
  end

  defp require_credentials(_client), do: {:error, :missing_credentials}

  defp sign_and_request(params, client, method, path) do
    query = URI.encode_query(params)
    signature = sign(query, client.api_secret)

    request_query(
      client,
      method,
      path,
      query <> "&signature=" <> signature,
      signed_headers(client)
    )
  end

  defp signed_headers(%__MODULE__{api_key: api_key}) do
    [{"X-MBX-APIKEY", api_key}]
  end

  defp request(%__MODULE__{} = client, method, path, params, headers) do
    url = client.base_url <> path

    opts =
      [
        method: method,
        url: url,
        headers: headers,
        params: params,
        receive_timeout: client.receive_timeout,
        finch: client.finch
      ]

    opts
    |> apply_request(client.request_fn)
    |> handle_response()
  end

  defp request_query(%__MODULE__{} = client, method, path, query, headers) do
    url = client.base_url <> path <> "?" <> query

    opts =
      [
        method: method,
        url: url,
        headers: headers,
        receive_timeout: client.receive_timeout,
        finch: client.finch
      ]

    opts
    |> apply_request(client.request_fn)
    |> handle_response()
  end

  defp apply_request(opts, request_fn) when is_function(request_fn, 1) do
    request_fn.(opts)
  end

  defp handle_response({:ok, response}) do
    status = Map.get(response, :status)
    body = Map.get(response, :body)

    if status in 200..299 do
      {:ok, body}
    else
      {:error, %{status: status, body: body}}
    end
  end

  defp handle_response({:error, reason}), do: {:error, reason}

  defp add_timestamp(params, recv_window) do
    params
    |> Keyword.put_new("timestamp", System.system_time(:millisecond))
    |> Keyword.put_new("recvWindow", recv_window)
  end

  defp normalize_params(params) when is_map(params) do
    params
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn {k, v} -> {to_string(k), normalize_value(v)} end)
    |> Enum.sort_by(fn {k, _v} -> k end)
  end

  defp normalize_params(params) when is_list(params) do
    params
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn {k, v} -> {to_string(k), normalize_value(v)} end)
    |> Enum.sort_by(fn {k, _v} -> k end)
  end

  defp normalize_value(value) when is_boolean(value), do: if(value, do: "true", else: "false")
  defp normalize_value(value), do: to_string(value)

  defp sign(query, secret) do
    :crypto.mac(:hmac, :sha256, secret, query)
    |> Base.encode16(case: :lower)
  end
end
