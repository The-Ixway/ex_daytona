defmodule ExDaytona.Testing.Server do
  @moduledoc false
  # Registry backing ExDaytona.Testing: HTTP expectations/stubs and
  # transport scripts, keyed by the owning (test) process. Started on
  # demand, never supervised — state for an owner is dropped when the
  # owner exits (each owner is monitored on first write).

  use GenServer

  @name __MODULE__

  ## Client ------------------------------------------------------------------

  def ensure_started do
    if Process.whereis(@name) do
      :ok
    else
      case GenServer.start(__MODULE__, :ok, name: @name) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end

  def add_expectation(owner, method, path, response),
    do: call({:add_expectation, owner, %{method: method, path: path, response: response}})

  def add_stub(owner, method, path, response),
    do: call({:add_stub, owner, %{method: method, path: path, response: response}})

  @doc false
  # Pop the first queued expectation matching (method, path) for the first
  # candidate owner that has one; fall back to stubs (not consumed).
  # Returns {:ok, response} or {:error, {:unexpected, remaining}}.
  def checkout(candidates, method, path), do: call({:checkout, candidates, method, path})

  def pending(owner), do: call({:pending, owner})

  def put_script(owner, kind, script), do: call({:put_script, owner, kind, script})

  def get_script(candidates, kind), do: call({:get_script, candidates, kind})

  defp call(message) do
    ensure_started()
    GenServer.call(@name, message)
  end

  ## Server ------------------------------------------------------------------

  @empty_owner %{expectations: [], stubs: [], scripts: %{}}

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:add_expectation, owner, expectation}, _from, state) do
    state =
      state
      |> ensure_owner(owner)
      |> update_in([owner, :expectations], &(&1 ++ [expectation]))

    {:reply, :ok, state}
  end

  def handle_call({:add_stub, owner, stub}, _from, state) do
    state =
      state
      |> ensure_owner(owner)
      |> update_in([owner, :stubs], &(&1 ++ [stub]))

    {:reply, :ok, state}
  end

  def handle_call({:put_script, owner, kind, script}, _from, state) do
    state =
      state
      |> ensure_owner(owner)
      |> put_in([owner, :scripts, kind], script)

    {:reply, :ok, state}
  end

  def handle_call({:get_script, candidates, kind}, _from, state) do
    script =
      Enum.find_value(candidates, fn pid ->
        state |> Map.get(pid, @empty_owner) |> Map.fetch!(:scripts) |> Map.get(kind)
      end)

    {:reply, script, state}
  end

  def handle_call({:checkout, candidates, method, path}, _from, state) do
    known = Enum.filter(candidates, &Map.has_key?(state, &1))

    case try_checkout(known, state, method, path) do
      {:ok, response, state} ->
        {:reply, {:ok, response}, state}

      :nomatch ->
        remaining =
          case known do
            [] -> []
            [first | _] -> state |> Map.fetch!(first) |> Map.fetch!(:expectations)
          end

        {:reply, {:error, {:unexpected, remaining}}, state}
    end
  end

  def handle_call({:pending, owner}, _from, state) do
    {:reply, state |> Map.get(owner, @empty_owner) |> Map.fetch!(:expectations), state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, Map.delete(state, pid)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  ## Internals ---------------------------------------------------------------

  defp ensure_owner(state, owner) do
    if Map.has_key?(state, owner) do
      state
    else
      Process.monitor(owner)
      Map.put(state, owner, @empty_owner)
    end
  end

  defp try_checkout([], _state, _method, _path), do: :nomatch

  defp try_checkout([owner | rest], state, method, path) do
    owner_state = Map.fetch!(state, owner)

    case pop_expectation(owner_state.expectations, method, path) do
      {:ok, expectation, remaining} ->
        {:ok, expectation.response, put_in(state, [owner, :expectations], remaining)}

      :nomatch ->
        case Enum.find(owner_state.stubs, &matches?(&1, method, path)) do
          %{response: response} -> {:ok, response, state}
          nil -> try_checkout(rest, state, method, path)
        end
    end
  end

  defp pop_expectation(expectations, method, path) do
    case Enum.split_while(expectations, &(not matches?(&1, method, path))) do
      {_prefix, []} -> :nomatch
      {prefix, [match | rest]} -> {:ok, match, prefix ++ rest}
    end
  end

  # Toolbox/analytics connections prefix their own base paths, so an
  # expectation path also matches as a suffix of the request path.
  defp matches?(%{method: method, path: expected}, method, path) do
    expected == path or String.ends_with?(path, expected)
  end

  defp matches?(_expectation, _method, _path), do: false
end
