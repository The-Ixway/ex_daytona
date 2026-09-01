defmodule ExDaytona.Snapshot do
  @moduledoc """
  Prebuilt sandbox snapshots: build once, create sandboxes instantly.

  Building a sandbox from an `ExDaytona.Image` runs the Docker build on
  every create. The fast production pattern is to build a **snapshot**
  from the image once and create every sandbox from it:

      image =
        ExDaytona.Image.from("ubuntu:22.04")
        |> ExDaytona.Image.run("apt-get update && apt-get install -y curl git")

      {:ok, snapshot} =
        ExDaytona.Snapshot.build(client, "my-app-base", image, log: &IO.write/1)

      # From here on, creation skips the build entirely:
      {:ok, sandbox} = ExDaytona.Sandbox.create(client, snapshot: "my-app-base")

  Snapshots can also wrap a registry image (`image_name:`) instead of a
  declarative build, and can be deactivated/reactivated to manage the
  organization's snapshot quota (`ExDaytona.Quota.overview/2` reports
  usage). For pre-warmed *running* sandboxes on top of a snapshot, see
  `ExDaytona.WarmPool`.
  """

  alias ExDaytona.Api
  alias ExDaytona.Client
  alias ExDaytona.Error
  alias ExDaytona.Model

  @error_states ~w(error build_failed)

  # snake_case facade option -> CreateSnapshot model field
  @create_fields %{
    image_name: :imageName,
    entrypoint: :entrypoint,
    cpu: :cpu,
    memory: :memory,
    disk: :disk,
    gpu: :gpu,
    gpu_type: :gpuType,
    region_id: :regionId,
    sandbox_class: :sandboxClass
  }

  @doc """
  Create a snapshot named `name` and (by default) wait for it to become
  `active`.

  ## Options

  - `:image` — build declaratively: an `ExDaytona.Image` or a raw
    Dockerfile string (local build contexts are uploaded automatically,
    as in `ExDaytona.Sandbox.create/2`)
  - `:image_name` — wrap an existing registry image instead of building
  - `:wait` — wait until the snapshot is `active` (default `true`)
  - `:timeout` — max milliseconds to wait (default `300_000` — builds
    take longer than sandbox starts)
  - `:poll_interval` — milliseconds between state polls (default `2_000`)
  - snapshot settings, all optional: `:entrypoint` (list), `:cpu`,
    `:memory`, `:disk`, `:gpu`, `:gpu_type`, `:region_id`,
    `:sandbox_class`

  Returns `{:ok, %ExDaytona.Model.SnapshotDto{}}`. Watch a build in
  progress with `stream_build_logs/4`, or use `build/4` to do both in
  one call.
  """
  @spec create(Client.t(), String.t(), keyword()) ::
          {:ok, Model.SnapshotDto.t()} | {:error, Error.t()}
  def create(%Client{} = client, name, opts \\ []) when is_binary(name) do
    {wait_opts, opts} = Keyword.split(opts, [:wait, :timeout, :poll_interval])
    {image, opts} = Keyword.pop(opts, :image)

    ExDaytona.Telemetry.span(
      [:snapshot, :create],
      %{name: name},
      fn -> do_create(client, name, image, opts, wait_opts) end,
      &snapshot_id_metadata/1
    )
  end

  defp do_create(client, name, image, opts, wait_opts) do
    with {:ok, model} <- build_create_model(name, opts),
         {:ok, model} <- apply_image(model, image, client),
         {:ok, %Model.SnapshotDto{} = snapshot} <-
           Error.normalize(Api.Snapshots.create_snapshot(client.conn, model, response: :full)) do
      if Keyword.get(wait_opts, :wait, true) do
        await_state(client, snapshot.id, "active", wait_opts)
      else
        {:ok, snapshot}
      end
    end
  end

  @doc """
  Build a snapshot from an image and wait for it to become `active` —
  `create/3` with the image required and optional live build-log
  streaming:

      {:ok, snapshot} =
        ExDaytona.Snapshot.build(client, "my-app-base", image,
          log: &IO.write/1,
          timeout: 600_000
        )

  ## Options

  - `:log` — a fun invoked with each build-log chunk while the build
    runs (streamed concurrently via `stream_build_logs/4`)
  - everything `create/3` accepts except `:image`/`:wait` (build always
    waits — a snapshot is only useful `active`)
  """
  @spec build(Client.t(), String.t(), ExDaytona.Image.t() | String.t(), keyword()) ::
          {:ok, Model.SnapshotDto.t()} | {:error, Error.t()}
  def build(%Client{} = client, name, image, opts \\ []) when is_binary(name) do
    {log_fun, opts} = Keyword.pop(opts, :log)
    {wait_opts, opts} = Keyword.split(opts, [:timeout, :poll_interval])

    ExDaytona.Telemetry.span(
      [:snapshot, :build],
      %{name: name},
      fn ->
        with {:ok, %Model.SnapshotDto{} = snapshot} <-
               create(client, name, [image: image, wait: false] ++ Keyword.delete(opts, :wait)) do
          follow = start_log_follow(client, snapshot.id, log_fun)

          try do
            await_state(client, snapshot.id, "active", wait_opts)
          after
            stop_log_follow(follow)
          end
        end
      end,
      &snapshot_id_metadata/1
    )
  end

  @doc """
  Fetch a snapshot by id or name as an `ExDaytona.Model.SnapshotDto`.
  """
  @spec get(Client.t(), String.t()) :: {:ok, Model.SnapshotDto.t()} | {:error, Error.t()}
  def get(%Client{} = client, id_or_name) when is_binary(id_or_name) do
    Error.normalize(Api.Snapshots.get_snapshot(client.conn, id_or_name, response: :full))
  end

  @doc """
  List snapshots. Accepts `:page`, `:limit`, `:name` (partial match),
  `:source_sandbox_id`, `:sort`, `:order`; returns
  `{:ok, %{items: [%ExDaytona.Model.SnapshotDto{}], page: n, total: n, total_pages: n}}`.
  """
  @spec list(Client.t(), keyword()) ::
          {:ok,
           %{
             items: [Model.SnapshotDto.t()],
             page: number() | nil,
             total: number() | nil,
             total_pages: number() | nil
           }}
          | {:error, Error.t()}
  def list(%Client{} = client, opts \\ []) do
    opts =
      case Keyword.pop(opts, :source_sandbox_id) do
        {nil, opts} -> opts
        {id, opts} -> Keyword.put(opts, :sourceSandboxId, id)
      end

    with {:ok, %Model.PaginatedSnapshots{} = page} <-
           Error.normalize(Api.Snapshots.get_all_snapshots(client.conn, opts ++ [response: :full])) do
      {:ok,
       %{
         items: page.items || [],
         page: page.page,
         total: page.total,
         total_pages: page.totalPages
       }}
    end
  end

  @doc """
  Delete a snapshot by id. Returns `:ok`.
  """
  @spec delete(Client.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete(%Client{} = client, snapshot_id) when is_binary(snapshot_id) do
    ExDaytona.Telemetry.span([:snapshot, :delete], %{snapshot_id: snapshot_id}, fn ->
      with {:ok, _} <-
             Error.normalize(Api.Snapshots.remove_snapshot(client.conn, snapshot_id, response: :full)) do
        :ok
      end
    end)
  end

  @doc """
  Reactivate a deactivated snapshot. Returns the updated
  `ExDaytona.Model.SnapshotDto`.
  """
  @spec activate(Client.t(), String.t()) :: {:ok, Model.SnapshotDto.t()} | {:error, Error.t()}
  def activate(%Client{} = client, snapshot_id) when is_binary(snapshot_id) do
    Error.normalize(Api.Snapshots.activate_snapshot(client.conn, snapshot_id, response: :full))
  end

  @doc """
  Deactivate a snapshot (it stops counting toward active usage; sandboxes
  can no longer be created from it until reactivated). Returns `:ok`.
  """
  @spec deactivate(Client.t(), String.t()) :: :ok | {:error, Error.t()}
  def deactivate(%Client{} = client, snapshot_id) when is_binary(snapshot_id) do
    with {:ok, _} <-
           Error.normalize(Api.Snapshots.deactivate_snapshot(client.conn, snapshot_id, response: :full)) do
      :ok
    end
  end

  @doc """
  Poll until the snapshot reaches `state` (a string or list of strings,
  e.g. `"active"`).

  Fails fast with `{:error, %Error{}}` when the snapshot enters an error
  state (`#{inspect(@error_states)}`, with the provider's `errorReason`
  in the message), and with a timeout error after `:timeout` milliseconds
  (default `300_000`; poll interval `:poll_interval`, default `2_000`).
  """
  @spec await_state(Client.t(), String.t(), String.t() | [String.t()], keyword()) ::
          {:ok, Model.SnapshotDto.t()} | {:error, Error.t()}
  def await_state(%Client{} = client, snapshot_id, state, opts \\ []) do
    target = List.wrap(state)
    timeout = Keyword.get(opts, :timeout, 300_000)
    interval = Keyword.get(opts, :poll_interval, 2_000)
    deadline = System.monotonic_time(:millisecond) + timeout

    poll_state(client, snapshot_id, target, interval, deadline)
  end

  @doc """
  The snapshot's build logs so far, as a binary. Only snapshots created
  from build info have build logs.
  """
  @spec build_logs(Client.t(), String.t()) :: {:ok, binary()} | {:error, Error.t()}
  def build_logs(%Client{} = client, snapshot_id) when is_binary(snapshot_id) do
    with {:ok, %Tesla.Env{body: body}} <-
           Error.normalize(Api.Snapshots.get_snapshot_build_logs(client.conn, snapshot_id, response: :full)) do
      {:ok, body}
    end
  end

  @doc """
  Follow the snapshot's build logs in real time: `fun` is invoked with
  each chunk as it is produced, and the call returns `:ok` when the build
  finishes and the stream closes.

  Options: `:timeout` — max milliseconds to wait between chunks
  (default `:infinity`); `:deadline` — overall milliseconds for the
  stream.
  """
  @spec stream_build_logs(Client.t(), String.t(), (binary() -> any()), keyword()) ::
          :ok | {:error, Error.t()}
  def stream_build_logs(%Client{} = client, snapshot_id, fun, opts \\ [])
      when is_binary(snapshot_id) and is_function(fun, 1) do
    url = Client.base_url(client) <> "/snapshots/#{snapshot_id}/build-logs?follow=true"

    opts = Keyword.put_new(opts, :transport, Client.transport(client, :http_stream))
    ExDaytona.HTTPStream.get(url, client.api_key, fun, opts)
  end

  ## Internals ---------------------------------------------------------------

  defp build_create_model(name, opts) do
    Enum.reduce_while(opts, {:ok, %Model.CreateSnapshot{name: name}}, fn {key, value}, {:ok, model} ->
      case Map.fetch(@create_fields, key) do
        {:ok, field} ->
          {:cont, {:ok, Map.put(model, field, value)}}

        :error ->
          {:halt,
           {:error,
            %Error{
              message:
                "unknown snapshot option #{inspect(key)} — supported: :image, " <>
                  (@create_fields |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &inspect/1))
            }}}
      end
    end)
  end

  defp apply_image(model, nil, _client), do: {:ok, model}

  defp apply_image(model, image, client) do
    with {:ok, build_info} <- ExDaytona.Image.resolve_build_info(image, client) do
      {:ok, %{model | buildInfo: build_info}}
    end
  end

  defp snapshot_id_metadata({:ok, %Model.SnapshotDto{id: id}}), do: %{snapshot_id: id}
  defp snapshot_id_metadata(_other), do: %{}

  defp start_log_follow(_client, _snapshot_id, nil), do: nil

  defp start_log_follow(client, snapshot_id, fun) when is_function(fun, 1) do
    Task.async(fn -> stream_build_logs(client, snapshot_id, fun) end)
  end

  defp stop_log_follow(nil), do: :ok

  defp stop_log_follow(%Task{} = task) do
    # The provider closes the follow stream shortly after the build ends;
    # give it a moment, then cut it loose.
    Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp poll_state(client, snapshot_id, target, interval, deadline) do
    case get(client, snapshot_id) do
      {:ok, %Model.SnapshotDto{state: state} = snapshot} ->
        cond do
          state in target ->
            {:ok, snapshot}

          state in @error_states ->
            {:error,
             %Error{
               message:
                 "snapshot #{snapshot_id} entered state #{inspect(state)}" <>
                   error_reason_suffix(snapshot),
               details: snapshot
             }}

          System.monotonic_time(:millisecond) >= deadline ->
            {:error,
             %Error{
               message:
                 "timed out waiting for snapshot #{snapshot_id} to reach " <>
                   "#{inspect(target)} (still #{inspect(state)})",
               details: snapshot
             }}

          true ->
            Process.sleep(interval)
            poll_state(client, snapshot_id, target, interval, deadline)
        end

      {:error, _} = error ->
        error
    end
  end

  defp error_reason_suffix(%Model.SnapshotDto{errorReason: reason})
       when is_binary(reason) and reason != "",
       do: ": #{reason}"

  defp error_reason_suffix(_snapshot), do: ""
end
