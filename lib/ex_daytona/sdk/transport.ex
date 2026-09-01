defmodule ExDaytona.Transport do
  @moduledoc """
  Injectable transports for the SDK's streaming paths.

  Ordinary request/response calls already accept custom Tesla adapters and
  middleware; the *streaming* paths (chunked HTTP log follows, file
  transfer, websockets) historically bound directly to Finch and Mint.
  These narrow behaviours make them replaceable — primarily so tests can
  deterministically simulate partial bodies, stalls, disconnects, and
  malformed frames:

      {:ok, client} =
        ExDaytona.Client.new(
          api_key: key,
          transports: [http_stream: MyFakeHTTPStream, websocket: MyFakeWS]
        )

  The selection is carried on the `ExDaytona.Client` and flows into every
  derived toolbox connection, log stream, PTY, and file transfer. This is
  a testing seam, not a general transport framework — the behaviours are
  intentionally minimal.
  """

  @typedoc "The transport selection carried on a client."
  @type t :: %{http_stream: module(), websocket: module()}

  @defaults %{
    http_stream: ExDaytona.Transport.FinchStream,
    websocket: ExDaytona.WebSocket
  }

  @doc """
  Resolve a `:transports` option (keyword or map, possibly partial) to a
  full transport map.
  """
  @spec resolve(keyword() | map() | nil) :: t()
  def resolve(nil), do: @defaults

  def resolve(overrides) do
    Map.merge(@defaults, Map.new(overrides))
  end

  defmodule HTTPStream do
    @moduledoc """
    Behaviour for streaming HTTP transports (both directions).

    `stream/7` issues a request and folds over response events —
    `{:status, integer}`, `{:headers, [{name, value}]}`, and
    `{:data, binary}` — with the reducer able to halt consumption early.
    The request body may itself be a lazy `{:stream, Enumerable.t()}` for
    constant-memory uploads.
    """

    @type event :: {:status, non_neg_integer()} | {:headers, [{binary(), binary()}]} | {:data, binary()}
    @type body :: iodata() | {:stream, Enumerable.t()} | nil

    @doc """
    Options: `:receive_timeout` (idle timeout between response events, ms),
    `:pool` (implementation-specific pool selector).

    Returns `{:ok, acc}` when the response completed or the reducer
    halted, `{:error, reason, acc}` on transport failure.
    """
    @callback stream(
                method :: String.t(),
                url :: String.t(),
                headers :: [{binary(), binary()}],
                body :: body(),
                acc,
                (event(), acc -> {:cont, acc} | {:halt, acc}),
                opts :: keyword()
              ) :: {:ok, acc} | {:error, term(), acc}
              when acc: term()
  end

  defmodule WSHandle do
    @moduledoc """
    A websocket connection handle pairing the transport module with its
    connection pid. Returned by websocket-opening facade functions when a
    custom `:websocket` transport is configured; the default transport
    keeps returning a bare pid for 0.1.0 compatibility. Frame messages
    are always tagged with `pid`.
    """
    @enforce_keys [:mod, :pid]
    defstruct [:mod, :pid]

    @type t :: %__MODULE__{mod: module(), pid: pid()}
  end

  defmodule WebSocketClient do
    @moduledoc """
    Behaviour for websocket client transports.

    Implementations deliver frames to the owner as
    `{:ex_daytona_ws, pid, {:text | :binary, data}}` messages and signal
    the end with `{:ex_daytona_ws, pid, {:closed, reason}}` — the message
    protocol `ExDaytona.WebSocket` established.
    """

    @callback connect(url :: String.t(), api_key :: String.t(), opts :: keyword()) ::
                {:ok, pid()} | {:error, ExDaytona.Error.t()}
    @callback send_text(pid(), iodata()) :: :ok | {:error, ExDaytona.Error.t()}
    @callback send_binary(pid(), iodata()) :: :ok | {:error, ExDaytona.Error.t()}
    @callback close(pid()) :: :ok
  end
end
