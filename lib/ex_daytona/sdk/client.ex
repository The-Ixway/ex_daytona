defmodule ExDaytona.Client do
  @moduledoc """
  Entry point for the high-level ExDaytona SDK facade.

  Wraps the generated low-level connection with idiomatic defaults: the API
  key comes from the `:api_key` option or the `DAYTONA_API_KEY` environment
  variable, and every facade function returns `{:ok, value}` or
  `{:error, %ExDaytona.Error{}}` — never the raw openapi-generator response
  conventions.

      {:ok, client} = ExDaytona.Client.new()
      {:ok, sandbox} = ExDaytona.Sandbox.create(client, snapshot: "...")

  The generated `ExDaytona.Api.*` modules remain available for the long tail
  of endpoints the facade doesn't cover — build a connection for them with
  `conn/1`.
  """

  alias ExDaytona.Connection
  alias ExDaytona.Error

  @enforce_keys [:conn, :api_key, :options]
  defstruct [:conn, :api_key, :options, transports: nil]

  @typedoc """
  A configured SDK client.

  - `conn` — the underlying Tesla client for the main platform API
  - `api_key` — the Daytona API key (also used for toolbox connections)
  - `options` — the connection options the client was built with (minus
    `base_url`/`bearer_token`), reused when deriving toolbox connections
  """
  @type t :: %__MODULE__{
          conn: Tesla.Env.client(),
          api_key: String.t(),
          options: keyword(),
          transports: ExDaytona.Transport.t()
        }

  @doc """
  Build a client for the Daytona platform API.

  ## Options

  - `:api_key` — Daytona API key (default: the `DAYTONA_API_KEY` environment
    variable)
  - all other options are passed through to
    `ExDaytona.Connection.new/1` (`:base_url`, `:retry`, `:timeout`,
    `:middleware`, ...)

  Returns `{:error, %ExDaytona.Error{}}` when no API key is available.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options \\ []) do
    {api_key, options} = Keyword.pop(options, :api_key, System.get_env("DAYTONA_API_KEY"))
    {transports, options} = Keyword.pop(options, :transports)

    if is_binary(api_key) and api_key != "" do
      conn = Connection.new([bearer_token: api_key] ++ options)

      {:ok,
       %__MODULE__{
         conn: conn,
         api_key: api_key,
         options: options,
         transports: ExDaytona.Transport.resolve(transports)
       }}
    else
      {:error,
       %Error{
         message: "no API key: pass api_key: \"dtn_...\" or set the DAYTONA_API_KEY environment variable"
       }}
    end
  end

  @doc """
  Same as `new/1`, but raises `ArgumentError` when no API key is available.
  """
  @spec new!(keyword()) :: t()
  def new!(options \\ []) do
    case new(options) do
      {:ok, client} -> client
      {:error, %Error{message: message}} -> raise ArgumentError, message
    end
  end

  @doc """
  The underlying Tesla client, for calling generated `ExDaytona.Api.*`
  functions the facade doesn't cover:

      {:ok, client} = ExDaytona.Client.new()
      ExDaytona.Api.Snapshots.get_all_snapshots(ExDaytona.Client.conn(client))
  """
  @spec conn(t()) :: Tesla.Env.client()
  def conn(%__MODULE__{conn: conn}), do: conn

  @doc """
  The configured transport implementation for `key` (`:http_stream` or
  `:websocket`) — see `ExDaytona.Transport`.
  """
  @spec transport(t(), :http_stream | :websocket) :: module()
  def transport(%__MODULE__{transports: transports}, key) do
    Map.fetch!(ExDaytona.Transport.resolve(transports), key)
  end

  @doc """
  The platform base URL this client targets, resolved the same way
  `ExDaytona.Connection.new/1` resolves it (explicit option, then the
  `:base_url` application env, then the production default).
  """
  @spec base_url(t()) :: String.t()
  def base_url(%__MODULE__{options: options}) do
    Keyword.get(
      options,
      :base_url,
      Application.get_env(:ex_daytona, :base_url, "https://app.daytona.io/api")
    )
  end
end
