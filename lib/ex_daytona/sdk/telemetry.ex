defmodule ExDaytona.Telemetry do
  @moduledoc """
  Domain-level `:telemetry` events emitted by the SDK facade.

  Tesla already emits HTTP-level events for every request; these spans sit
  above that, at the level operations dashboards actually chart — sandbox
  lifecycle, command execution, file transfer. Each operation emits the
  standard `:telemetry.span/3` triple:

  - `[:ex_daytona, <area>, <op>, :start]` — measurements
    `%{monotonic_time, system_time}`
  - `[:ex_daytona, <area>, <op>, :stop]` — measurements
    `%{duration, monotonic_time}` (`duration` in native units)
  - `[:ex_daytona, <area>, <op>, :exception]` — when the operation raised

  ## Events

  | Event prefix | Start metadata | Extra stop metadata |
  | --- | --- | --- |
  | `[:ex_daytona, :sandbox, :create]` | — | `sandbox_id` |
  | `[:ex_daytona, :sandbox, :start]` | `sandbox_id` | |
  | `[:ex_daytona, :sandbox, :stop]` | `sandbox_id` | |
  | `[:ex_daytona, :sandbox, :delete]` | `sandbox_id` | |
  | `[:ex_daytona, :sandbox, :exec]` | `sandbox_id` | `exit_code` |
  | `[:ex_daytona, :sandbox, :run_code]` | `sandbox_id`, `language` | `exit_code` |
  | `[:ex_daytona, :session, :run]` | `sandbox_id`, `session_id` | `exit_code` |
  | `[:ex_daytona, :fs, :upload]` | `sandbox_id` | `bytes` |
  | `[:ex_daytona, :fs, :download]` | `sandbox_id` | `bytes` |
  | `[:ex_daytona, :snapshot, :create]` | `name` | `snapshot_id` |
  | `[:ex_daytona, :snapshot, :build]` | `name` | `snapshot_id` |
  | `[:ex_daytona, :snapshot, :delete]` | `snapshot_id` | |

  Every `:stop` event's metadata also carries the outcome:

  - `outcome` — `:ok` or `:error`
  - `error_code` — the provider's error code string (or `nil`)
  - `error_status` — the HTTP status of the failure (or `nil`)

  The `:fs` events cover the constant-memory transfer engine
  (`upload_stream`/`upload_file`, `download_stream`/`download_file`,
  `stream!`).

  Metadata is deliberately **redaction-safe**: identifiers, languages,
  exit codes, and byte counts only — never command lines, file paths,
  environment values, or payloads.

      :telemetry.attach(
        "ex-daytona-exec-timing",
        [:ex_daytona, :sandbox, :exec, :stop],
        fn _event, %{duration: duration}, meta, _config ->
          ms = System.convert_time_unit(duration, :native, :millisecond)
          Logger.info("exec on \#{meta.sandbox_id}: \#{meta.outcome} in \#{ms}ms")
        end,
        nil
      )
  """

  alias ExDaytona.Error

  @doc false
  # Wrap a facade operation in a :telemetry.span. `fun` returns the
  # operation's normal result ({:ok, _} | {:error, %Error{}} | :ok);
  # outcome metadata is derived from it, and `result_metadata` can add
  # result-derived fields (ids, byte counts) to the stop event.
  @spec span([atom()], map(), (-> result), (result -> map())) :: result when result: term()
  def span(event, metadata, fun, result_metadata \\ fn _result -> %{} end) do
    :telemetry.span([:ex_daytona | event], metadata, fn ->
      result = fun.()

      stop_metadata =
        metadata
        |> Map.merge(outcome_metadata(result))
        |> Map.merge(result_metadata.(result))

      {result, stop_metadata}
    end)
  end

  defp outcome_metadata({:error, %Error{} = error}),
    do: %{outcome: :error, error_code: error.code, error_status: error.status}

  defp outcome_metadata({:error, _reason}),
    do: %{outcome: :error, error_code: nil, error_status: nil}

  defp outcome_metadata(_result), do: %{outcome: :ok, error_code: nil, error_status: nil}
end
