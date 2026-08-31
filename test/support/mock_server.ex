defmodule MockServer do
  @moduledoc """
  Mock HTTP server for tests, running on Bandit (pure Elixir — no
  cowboy/cowlib in the dependency tree).

  API-compatible with the subset of Bypass this suite grew up on:
  `open/0` (alias `setup/0`), `expect/2` (catch-all), `expect/4`,
  `expect_once/4`, `down/1`, and a struct with a `.port` field — plus the
  `expect_get/post/put/delete/error` conveniences.

  Semantics match Bypass:

  - `expect_once/4` — the route must be hit exactly once; multiple
    registrations for the same route queue up FIFO
  - `expect/4` and `expect/2` — must be hit at least once, any number of
    times
  - unexpected requests answer 500 and fail the test on exit, as do
    unmet expectations

  ## Usage

      setup do
        bypass = MockServer.setup()
        {:ok, bypass: bypass}
      end

      test "makes API call", %{bypass: bypass} do
        MockServer.expect_get(bypass, "/users/1", 200, %{id: 1, name: "Test"})
        # ...
      end
  """

  use GenServer

  defstruct [:pid, :server, :port]

  ## Bypass-compatible API ----------------------------------------------------

  @doc """
  Start a mock server on an ephemeral port. Registers an on-exit hook
  that stops it and fails the test on unmet/unexpected requests.
  """
  def open do
    {:ok, pid} = GenServer.start(__MODULE__, self())

    {:ok, server} =
      Bandit.start_link(plug: {MockServer.Plug, pid}, port: 0, startup_log: false)

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    state = %__MODULE__{pid: pid, server: server, port: port}

    ExUnit.Callbacks.on_exit(fn ->
      verify_and_stop(state)
    end)

    state
  end

  @doc "Alias for `open/0` (the name this suite's setups use)."
  def setup, do: open()

  @doc """
  Expect at least one request matching `method` and `path`; `fun`
  receives the `Plug.Conn`.
  """
  def expect(%__MODULE__{pid: pid}, method, path, fun) when is_function(fun, 1) do
    GenServer.call(pid, {:register, {method, path}, :many, fun})
  end

  @doc """
  Catch-all variant: expect at least one request of any method/path.
  """
  def expect(%__MODULE__{pid: pid}, fun) when is_function(fun, 1) do
    GenServer.call(pid, {:register, :any, :many, fun})
  end

  @doc """
  Expect exactly one request matching `method` and `path`. Repeated
  registrations for the same route queue in order.
  """
  def expect_once(%__MODULE__{pid: pid}, method, path, fun) when is_function(fun, 1) do
    GenServer.call(pid, {:register, {method, path}, :once, fun})
  end

  @doc """
  Stop the listener so subsequent connections are refused (for
  transport-error tests). Skips exit-time verification.
  """
  def down(%__MODULE__{pid: pid, server: server}) do
    GenServer.call(pid, :skip_verification)
    stop_server(server)
    :ok
  end

  ## Convenience helpers ------------------------------------------------------

  @doc "Expect one GET returning `status` with a JSON body."
  def expect_get(bypass, path, status \\ 200, response_body \\ %{}) do
    expect_once(bypass, "GET", path, &json_response(&1, status, response_body))
  end

  @doc "Expect one POST returning `status` with a JSON body."
  def expect_post(bypass, path, status \\ 201, response_body \\ %{}) do
    expect_once(bypass, "POST", path, &json_response(&1, status, response_body))
  end

  @doc "Expect one PUT returning `status` with a JSON body."
  def expect_put(bypass, path, status \\ 200, response_body \\ %{}) do
    expect_once(bypass, "PUT", path, &json_response(&1, status, response_body))
  end

  @doc "Expect one DELETE returning `status` (empty body by default)."
  def expect_delete(bypass, path, status \\ 204, response_body \\ "") do
    expect_once(bypass, "DELETE", path, fn conn ->
      body = if response_body == "", do: "", else: JSON.encode!(response_body)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, body)
    end)
  end

  @doc "Expect any request and answer it with an error `status`."
  def expect_error(bypass, status \\ 500) do
    expect(bypass, fn conn -> Plug.Conn.resp(conn, status, "") end)
  end

  @doc "The server's base URL."
  def url(%__MODULE__{port: port}), do: "http://localhost:#{port}"

  @doc "The server's base URL plus `path`."
  def url(%__MODULE__{} = server, path), do: url(server) <> path

  defp json_response(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, JSON.encode!(body))
  end

  ## Expectation bookkeeping (GenServer) -------------------------------------

  @impl true
  def init(_test_pid) do
    {:ok, %{routes: %{}, violations: [], verify?: true}}
  end

  @impl true
  def handle_call({:register, key, mode, fun}, _from, state) do
    routes =
      Map.update(
        state.routes,
        key,
        %{mode: mode, funs: [fun], hits: 0},
        fn route -> %{route | funs: route.funs ++ [fun]} end
      )

    {:reply, :ok, %{state | routes: routes}}
  end

  def handle_call({:claim, method, path}, _from, state) do
    key =
      cond do
        Map.has_key?(state.routes, {method, path}) -> {method, path}
        Map.has_key?(state.routes, :any) -> :any
        true -> nil
      end

    case key && state.routes[key] do
      nil ->
        violation = "unexpected #{method} #{path}"
        {:reply, :unexpected, %{state | violations: [violation | state.violations]}}

      %{mode: :once, funs: []} ->
        violation = "extra #{method} #{path} (all expect_once handlers already used)"
        {:reply, :unexpected, %{state | violations: [violation | state.violations]}}

      %{mode: :once, funs: [fun | rest]} = route ->
        routes = Map.put(state.routes, key, %{route | funs: rest, hits: route.hits + 1})
        {:reply, {:run, fun}, %{state | routes: routes}}

      %{mode: :many, funs: [fun | _]} = route ->
        routes = Map.put(state.routes, key, %{route | hits: route.hits + 1})
        {:reply, {:run, fun}, %{state | routes: routes}}
    end
  end

  def handle_call(:skip_verification, _from, state) do
    {:reply, :ok, %{state | verify?: false}}
  end

  def handle_call(:verify, _from, state) do
    unmet =
      for {key, route} <- state.routes, problem = unmet_problem(key, route), problem != nil do
        problem
      end

    result =
      case {state.verify?, state.violations, unmet} do
        {false, _, _} -> :ok
        {true, [], []} -> :ok
        {true, violations, unmet} -> {:error, Enum.reverse(violations) ++ unmet}
      end

    {:reply, result, state}
  end

  defp unmet_problem(key, %{mode: :once, funs: funs}) when funs != [] do
    "#{length(funs)} expected request(s) never arrived: #{describe(key)}"
  end

  defp unmet_problem(key, %{mode: :many, hits: 0}) do
    "expected request never arrived: #{describe(key)}"
  end

  defp unmet_problem(_key, _route), do: nil

  defp describe(:any), do: "(any request)"
  defp describe({method, path}), do: "#{method} #{path}"

  defp verify_and_stop(%__MODULE__{pid: pid, server: server}) do
    result =
      if Process.alive?(pid) do
        GenServer.call(pid, :verify)
      else
        :ok
      end

    stop_server(server)
    if Process.alive?(pid), do: GenServer.stop(pid)

    case result do
      :ok -> :ok
      {:error, problems} -> raise "MockServer expectations failed:\n  " <> Enum.join(problems, "\n  ")
    end
  end

  defp stop_server(server) do
    if Process.alive?(server), do: Supervisor.stop(server)
  catch
    :exit, _ -> :ok
  end

  defmodule Plug do
    @moduledoc false
    @behaviour Elixir.Plug

    alias Elixir.Plug.Conn

    @impl true
    def init(pid), do: pid

    @impl true
    def call(conn, pid) do
      case GenServer.call(pid, {:claim, conn.method, conn.request_path}) do
        {:run, fun} ->
          fun.(conn)

        :unexpected ->
          Conn.resp(conn, 500, "unexpected request to MockServer")
      end
    end
  end
end
