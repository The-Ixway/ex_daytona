defmodule SdkSurface do
  @moduledoc """
  Reflection helpers for the generated SDK surface.

  The template's tests must work for any minted SDK without knowing its
  module namespace at authoring time. This module discovers the namespace
  and the generated modules at runtime from the application's module list,
  so the surface tests survive every regeneration (and any renaming of the
  SDK) with zero maintenance.
  """

  @app Mix.Project.config()[:app]

  def app, do: @app

  @doc "The SDK's root module namespace (e.g. `MyAPIClient`)."
  def namespace do
    connection_module()
    |> Module.split()
    |> Enum.drop(-1)
    |> Module.concat()
  end

  def connection_module, do: find_module("Connection")
  def request_builder_module, do: find_module("RequestBuilder")
  def deserializer_module, do: find_module("Deserializer")

  @doc "The Finch pool name used by the default adapter."
  def finch_name, do: Module.concat(namespace(), Finch)

  @doc "All generated `<Namespace>.Api.*` modules."
  def api_modules, do: modules_under("Api")

  @doc "All generated `<Namespace>.Model.*` modules."
  def model_modules, do: modules_under("Model")

  @doc """
  One arbitrary (but deterministic) generated model module — useful for
  tests that need any concrete model struct.
  """
  def sample_model_module do
    model_modules() |> Enum.min_by(&Atom.to_string/1)
  end

  defp modules_under(segment) do
    prefix = Atom.to_string(namespace()) <> "." <> segment <> "."

    Enum.filter(app_modules(), fn module ->
      String.starts_with?(Atom.to_string(module), prefix)
    end)
  end

  # A spec schema could itself be named e.g. "Connection" (generating
  # <Namespace>.Model.Connection), so prefer the shortest module path — the
  # template-owned runtime module lives directly under the namespace.
  defp find_module(suffix) do
    app_modules()
    |> Enum.filter(fn module ->
      module |> Atom.to_string() |> String.ends_with?("." <> suffix)
    end)
    |> Enum.min_by(&length(Module.split(&1)), fn ->
      raise "no module ending in .#{suffix} found in #{inspect(@app)}"
    end)
  end

  defp app_modules do
    {:ok, modules} = :application.get_key(@app, :modules)
    modules
  end
end
