defmodule ExDaytona.Testing.UnexpectedRequestError do
  @moduledoc """
  Raised when an `ExDaytona.Testing` client receives a request no
  expectation or stub matches.
  """
  defexception [:message]
end

defmodule ExDaytona.Testing.VerificationError do
  @moduledoc """
  Raised by `ExDaytona.Testing.verify!/0` when expectations were not
  consumed.
  """
  defexception [:message]
end

defmodule ExDaytona.Testing do
  @moduledoc """
  First-class test doubles for applications built on ExDaytona — no
  Daytona account, API key, or network required.

  `client/1` returns a real `ExDaytona.Client` whose HTTP adapter and
  streaming transports are backed by scripts owned by the calling (test)
  process. Every facade module works against it unchanged:

      test "provisions a sandbox per tenant" do
        client = ExDaytona.Testing.client()

        ExDaytona.Testing.expect(:post, "/sandbox", fn env ->
          assert %{"labels" => %{"my-app/tenant" => "user-1"}} = JSON.decode!(env.body)
          {200, ExDaytona.Testing.sandbox_json(%{id: "sb-1"})}
        end)

        # Sandbox.create polls state until "started" — stub the poll.
        ExDaytona.Testing.stub(:get, "/sandbox/sb-1", ExDaytona.Testing.sandbox_json(%{id: "sb-1"}))

        assert {:ok, sandbox} =
                 MyApp.Sandboxes.provision(client, tenant: "user-1")

        assert ExDaytona.Sandbox.id(sandbox) == "sb-1"
        ExDaytona.Testing.verify!()
      end

  ## Expectations and stubs

  - `expect/3` queues a one-shot response consumed FIFO per
    `{method, path}`; `verify!/0` fails the test if any remain.
  - `stub/3` registers a reusable fallback (state polls, repeated
    lookups); stubs are consulted after expectations and never consumed.
  - A path matches when it equals the request path **or is a suffix of
    it** — so `"/process/execute"` matches the toolbox route
    `"/{sandbox_id}/process/execute"` without spelling out the prefix.
  - Responses: `{status, body}` (maps/lists JSON-encoded, binaries sent
    raw), a bare body (status 200), a bare status, `status:`/`body:`/
    `headers:` keywords, `{:error, reason}` to simulate a transport
    failure, or a fun of the `Tesla.Env` returning any of these — use a
    fun to assert on the request itself.

  Everything is keyed by the test process, so `async: true` tests don't
  interfere; state is cleaned up when the test process exits. Requests
  made by processes the SDK spawns internally (pollers, log followers)
  resolve to the client's owner automatically.

  ## Sandboxes without HTTP

  Facades that operate *on* a sandbox (`ExDaytona.FS`,
  `ExDaytona.Session`, `ExDaytona.Git`, ...) take a sandbox struct —
  build one directly with `sandbox/2` and skip the create flow entirely:

      sandbox = ExDaytona.Testing.sandbox(%{id: "sb-1"})

      ExDaytona.Testing.expect(:post, "/process/execute", %{exitCode: 0, result: "hi"})
      assert {:ok, %{exit_code: 0}} = ExDaytona.Sandbox.exec(sandbox, "echo hi")

  ## Streaming

  HTTP chunk streams (log follows, `ExDaytona.FS` transfers) and
  websockets (`ExDaytona.LogStream`, `ExDaytona.Pty`,
  `ExDaytona.CodeInterpreter`) bypass the Tesla adapter — script them
  with `script_http_stream/1` and `script_ws/1`:

      ExDaytona.Testing.script_ws(frames: [{:binary, <<1, 1, 1>> <> "hello"}])

      {:ok, stream} = ExDaytona.Session.open_log_stream(session, cmd_id)
      assert {:ok, %{stdout: "hello"}} = ExDaytona.LogStream.collect(stream)
  """

  alias ExDaytona.Client
  alias ExDaytona.Model
  alias ExDaytona.Testing.Server

  @default_toolbox_proxy_url "http://toolbox.ex-daytona.testing"

  # snake_case conveniences for sandbox/2 and sandbox_json/1 attrs
  @sandbox_snake_fields %{
    toolbox_proxy_url: :toolboxProxyUrl,
    organization_id: :organizationId,
    error_reason: :errorReason
  }

  @doc """
  A ready-to-use `ExDaytona.Client` backed entirely by this process's
  scripts: the Tesla adapter answers from `expect/3`/`stub/3`, and the
  streaming transports from `script_http_stream/1`/`script_ws/1`.

  Options are passed through to `ExDaytona.Client.new!/1` (`:base_url`,
  `:middleware`, ...); `:api_key` defaults to `"dtn_test"` and `:retry`
  to `false`.
  """
  @spec client(keyword()) :: Client.t()
  def client(opts \\ []) do
    Server.ensure_started()

    defaults = [
      api_key: "dtn_test",
      base_url: "http://api.ex-daytona.testing",
      retry: false,
      adapter: {ExDaytona.Testing.Adapter, owner: self()},
      transports: [
        http_stream: ExDaytona.Testing.HTTPStream,
        websocket: ExDaytona.Testing.WebSocket
      ]
    ]

    Client.new!(Keyword.merge(defaults, opts))
  end

  @doc """
  Queue a one-shot response for the next `method` request whose path
  matches `path` (exactly, or as a suffix — see the module docs).
  Consumed FIFO per `{method, path}`; leftovers fail `verify!/0`.

      ExDaytona.Testing.expect(:get, "/sandbox/sb-1", ExDaytona.Testing.sandbox_json())
      ExDaytona.Testing.expect(:delete, "/sandbox/sb-1", 200)
      ExDaytona.Testing.expect(:post, "/snapshots", fn env ->
        assert JSON.decode!(env.body)["name"] == "base"
        {200, %{id: "snap-1", name: "base", state: "active"}}
      end)
  """
  @spec expect(atom() | String.t(), String.t(), term()) :: :ok
  def expect(method, path, response) when is_binary(path) do
    Server.add_expectation(self(), normalize_method(method), path, response)
  end

  @doc """
  Register a reusable response for `method`/`path` — consulted whenever
  no expectation matches, never consumed, never verified. The tool for
  endpoints the SDK polls (sandbox state, snapshot state, command
  status).
  """
  @spec stub(atom() | String.t(), String.t(), term()) :: :ok
  def stub(method, path, response) when is_binary(path) do
    Server.add_stub(self(), normalize_method(method), path, response)
  end

  @doc """
  Raise `ExDaytona.Testing.VerificationError` unless every expectation
  queued by this process was consumed. Call it at the end of the test.
  """
  @spec verify!() :: :ok
  def verify! do
    case Server.pending(self()) do
      [] ->
        :ok

      remaining ->
        listed = Enum.map_join(remaining, "\n  ", &"#{&1.method} #{&1.path}")

        raise ExDaytona.Testing.VerificationError,
              "unmet ExDaytona.Testing expectations:\n  " <> listed
    end
  end

  @doc """
  A `%ExDaytona.Sandbox{}` struct for facades that operate on sandboxes,
  with no HTTP involved in building it. Defaults: id `"sandbox-test"`,
  state `"started"`, and a toolbox proxy URL — override any
  `ExDaytona.Model.Sandbox` field via `attrs` (snake_case conveniences
  `:toolbox_proxy_url`, `:organization_id`, `:error_reason` included).

  Pass a client as the first argument to bind the sandbox to it;
  otherwise a fresh `client/1` is built. `sandbox(attrs)` is accepted as
  a shorthand for `sandbox(nil, attrs)`.
  """
  @spec sandbox(Client.t() | map() | nil, map()) :: ExDaytona.Sandbox.t()
  def sandbox(client_or_attrs \\ nil, attrs \\ %{})

  def sandbox(nil, attrs) when is_map(attrs), do: sandbox(client(), attrs)

  def sandbox(%Client{} = client, attrs) when is_map(attrs) do
    defaults = %{
      id: "sandbox-test",
      state: "started",
      toolboxProxyUrl: @default_toolbox_proxy_url,
      organizationId: "org-test"
    }

    info = struct!(Model.Sandbox, Map.merge(defaults, normalize_sandbox_attrs(attrs)))
    %ExDaytona.Sandbox{client: client, info: info}
  end

  def sandbox(%{} = attrs, empty) when map_size(empty) == 0, do: sandbox(client(), attrs)

  @doc """
  A sandbox JSON body (string keys, camelCase — what the API sends) for
  use in `expect/3`/`stub/3` responses. Same defaults and snake_case
  conveniences as `sandbox/2`.
  """
  @spec sandbox_json(map()) :: map()
  def sandbox_json(attrs \\ %{}) when is_map(attrs) do
    defaults = %{
      "id" => "sandbox-test",
      "state" => "started",
      "toolboxProxyUrl" => @default_toolbox_proxy_url,
      "organizationId" => "org-test"
    }

    overrides =
      attrs
      |> normalize_sandbox_attrs()
      |> Map.new(fn
        {key, value} when is_atom(key) -> {Atom.to_string(key), value}
        {key, value} -> {key, value}
      end)

    Map.merge(defaults, overrides)
  end

  @doc """
  Script the next websocket connection opened by a process this test
  started (an `ExDaytona.LogStream`, `ExDaytona.Pty`, or
  `ExDaytona.CodeInterpreter` run against a `client/1`). The script stays
  in effect until replaced.

  ## Options

  - `:frames` — frames to replay, as `{:binary, data}` / `{:text, data}`
    tuples (log streams use 3-byte channel markers — `<<1, 1, 1>>`
    stdout, `<<2, 2, 2>>` stderr; unmarked bytes surface as `:output`)
  - `:frame_delay` — ms between frames (default `0`)
  - `:close_reason` — how the connection closes after the frames
    (default `:normal`; e.g. `{:error, :closed}` for a drop)
  - `:hold_open` — keep the connection open after the frames instead of
    closing (default `false`)
  - `:connect` — set to `{:error, %ExDaytona.Error{...}}` to fail the
    upgrade itself
  """
  @spec script_ws(keyword()) :: :ok
  def script_ws(opts) when is_list(opts) do
    Server.put_script(self(), :ws, Map.new(opts))
  end

  @doc """
  Script the next chunked HTTP stream (build-log follows,
  `ExDaytona.FS` uploads/downloads including `ExDaytona.FS.stream!/3`).
  The script stays in effect until replaced.

  ## Options

  - `:status` — response status (default `200`)
  - `:chunks` — body chunks to deliver in order (default `[]`)
  - `:chunk_delay` — ms between chunks (default `0`)
  - `:headers` — response headers (default `[]`)
  - `:error` — after the chunks, fail the transport with this reason
    instead of completing
  """
  @spec script_http_stream(keyword()) :: :ok
  def script_http_stream(opts) when is_list(opts) do
    Server.put_script(self(), :http_stream, Map.new(opts))
  end

  ## Internals ---------------------------------------------------------------

  defp normalize_method(method) when is_atom(method),
    do: method |> Atom.to_string() |> String.upcase()

  defp normalize_method(method) when is_binary(method), do: String.upcase(method)

  defp normalize_sandbox_attrs(attrs) do
    Map.new(attrs, fn {key, value} ->
      {Map.get(@sandbox_snake_fields, key, key), value}
    end)
  end
end
