defmodule ExDaytona.Image do
  @moduledoc """
  Declarative image definitions for building sandboxes (and snapshots)
  from a Dockerfile instead of a prebuilt snapshot.

      image =
        ExDaytona.Image.from("ubuntu:22.04")
        |> ExDaytona.Image.run("apt-get update && apt-get install -y curl git")
        |> ExDaytona.Image.env(%{"LANG" => "C.UTF-8"})
        |> ExDaytona.Image.workdir("/workspace")

      {:ok, sandbox} = ExDaytona.Sandbox.create(client, image: image)

      # Watch the build as it happens
      ExDaytona.Sandbox.stream_build_logs(sandbox, &IO.write/1)

  A raw Dockerfile works too — `ExDaytona.Sandbox.create/2` accepts
  `image: "FROM ubuntu:22.04\\n..."` directly, and `raw/1` wraps one in an
  `%ExDaytona.Image{}`.

  The DSL covers instructions that need no build context (`RUN`, `ENV`,
  `WORKDIR`, `USER`, `LABEL`, `EXPOSE`, `ENTRYPOINT`, `CMD`) plus
  `instruction/2` as an escape hatch for anything else. `COPY`/`ADD` of
  local files requires uploading a build context, which this SDK does not
  manage yet — bake files in with `RUN` (curl/git) or write them into the
  sandbox after creation.
  """

  alias ExDaytona.Model

  defstruct base: nil, raw: nil, instructions: []

  @type t :: %__MODULE__{
          base: String.t() | nil,
          raw: String.t() | nil,
          instructions: [String.t()]
        }

  @doc """
  Start an image definition from a base image reference.
  """
  @spec from(String.t()) :: t()
  def from(base) when is_binary(base), do: %__MODULE__{base: base}

  @doc """
  Wrap a complete raw Dockerfile.
  """
  @spec raw(String.t()) :: t()
  def raw(dockerfile) when is_binary(dockerfile), do: %__MODULE__{raw: dockerfile}

  @doc """
  Append a `RUN` instruction.
  """
  @spec run(t(), String.t()) :: t()
  def run(%__MODULE__{} = image, command) when is_binary(command) do
    append(image, "RUN " <> command)
  end

  @doc """
  Append `ENV` instructions from a map.
  """
  @spec env(t(), %{optional(String.t()) => String.t()}) :: t()
  def env(%__MODULE__{} = image, vars) when is_map(vars) do
    vars
    |> Enum.sort()
    |> Enum.reduce(image, fn {key, value}, acc ->
      append(acc, ~s(ENV #{key}="#{escape(value)}"))
    end)
  end

  @doc """
  Append a `WORKDIR` instruction.
  """
  @spec workdir(t(), String.t()) :: t()
  def workdir(%__MODULE__{} = image, dir) when is_binary(dir), do: append(image, "WORKDIR " <> dir)

  @doc """
  Append a `USER` instruction.
  """
  @spec user(t(), String.t()) :: t()
  def user(%__MODULE__{} = image, name) when is_binary(name), do: append(image, "USER " <> name)

  @doc """
  Append a `LABEL` instruction.
  """
  @spec label(t(), String.t(), String.t()) :: t()
  def label(%__MODULE__{} = image, key, value) when is_binary(key) and is_binary(value) do
    append(image, ~s(LABEL #{key}="#{escape(value)}"))
  end

  @doc """
  Append an `EXPOSE` instruction.
  """
  @spec expose(t(), pos_integer()) :: t()
  def expose(%__MODULE__{} = image, port) when is_integer(port) do
    append(image, "EXPOSE #{port}")
  end

  @doc """
  Set the `ENTRYPOINT` (exec form).
  """
  @spec entrypoint(t(), [String.t()]) :: t()
  def entrypoint(%__MODULE__{} = image, argv) when is_list(argv) do
    append(image, "ENTRYPOINT " <> JSON.encode!(argv))
  end

  @doc """
  Set the `CMD` (exec form).
  """
  @spec cmd(t(), [String.t()]) :: t()
  def cmd(%__MODULE__{} = image, argv) when is_list(argv) do
    append(image, "CMD " <> JSON.encode!(argv))
  end

  @doc """
  Append an arbitrary Dockerfile instruction line — the escape hatch for
  anything the DSL doesn't cover.
  """
  @spec instruction(t(), String.t()) :: t()
  def instruction(%__MODULE__{} = image, line) when is_binary(line), do: append(image, line)

  @doc """
  Render the definition to Dockerfile content.
  """
  @spec dockerfile(t() | String.t()) :: String.t()
  def dockerfile(dockerfile) when is_binary(dockerfile), do: dockerfile
  def dockerfile(%__MODULE__{raw: raw}) when is_binary(raw), do: raw

  def dockerfile(%__MODULE__{base: base, instructions: instructions}) when is_binary(base) do
    Enum.join(["FROM " <> base | Enum.reverse(instructions)], "\n") <> "\n"
  end

  @doc """
  The `ExDaytona.Model.CreateBuildInfo` for this image — what
  `ExDaytona.Sandbox.create/2` sends when given `image:`, and what the
  low-level snapshot API takes as `buildInfo`.
  """
  @spec build_info(t() | String.t()) :: Model.CreateBuildInfo.t()
  def build_info(image) do
    %Model.CreateBuildInfo{dockerfileContent: dockerfile(image)}
  end

  defp append(%__MODULE__{raw: raw}, _line) when is_binary(raw) do
    raise ArgumentError,
          "cannot append instructions to a raw Dockerfile image — edit the Dockerfile string instead"
  end

  defp append(%__MODULE__{instructions: instructions} = image, line) do
    %{image | instructions: [line | instructions]}
  end

  defp escape(value), do: String.replace(value, "\"", "\\\"")
end
