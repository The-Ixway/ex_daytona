defmodule ExDaytona.Error do
  @moduledoc """
  Normalized error for the SDK facade.

  The generated openapi-generator client returns three different shapes for
  failures (spec-declared error models as `{:ok, error_struct}`, undeclared
  statuses as `{:error, %Tesla.Env{}}`, and transport failures as
  `{:error, reason}`). `normalize/1` collapses all of them into
  `{:error, %ExDaytona.Error{}}` so facade callers match one shape:

  - `status` — HTTP status, or `nil` for transport failures
  - `message` — human-readable message
  - `code` — the API's error code string, when it sent one
  - `details` — the raw error payload (decoded map, model struct, or
    transport reason) for anything the other fields don't capture
  """

  alias ExDaytona.Model.ErrorResponse

  defstruct [:status, :message, :code, :details]

  @type t :: %__MODULE__{
          status: non_neg_integer() | nil,
          message: String.t() | nil,
          code: String.t() | nil,
          details: term()
        }

  @doc """
  Collapse a generated-client result into `{:ok, value}` or
  `{:error, %ExDaytona.Error{}}`.

  Success values (decoded models, lists, maps, and 2xx `Tesla.Env`
  passthroughs) are left untouched.
  """
  @spec normalize(term()) :: {:ok, term()} | {:error, t()}
  def normalize({:ok, %ErrorResponse{} = error}), do: {:error, from(error)}

  def normalize({:ok, %Tesla.Env{status: status} = env}) when status >= 400,
    do: {:error, from(env)}

  def normalize({:ok, value}), do: {:ok, value}

  # A 2xx the spec didn't declare: the generated client can only return it
  # as {:error, env}, but the server succeeded — the spec is just behind
  # (e.g. a 201 where the spec declares 200). Treat it as success.
  def normalize({:error, %Tesla.Env{status: status} = env}) when status in 200..299,
    do: {:ok, env}

  def normalize({:error, reason}), do: {:error, from(reason)}

  @doc """
  Build an `ExDaytona.Error` from any failure shape the generated client
  produces.
  """
  @spec from(term()) :: t()
  def from(%__MODULE__{} = error), do: error

  def from(%ErrorResponse{} = error) do
    %__MODULE__{
      status: error.statusCode,
      message: error.message,
      code: error.code,
      details: error
    }
  end

  def from(%Tesla.Env{status: status, body: body}) do
    %__MODULE__{
      status: status,
      message: message_from_body(body) || "HTTP #{status}",
      code: code_from_body(body),
      details: body
    }
  end

  def from(reason) do
    %__MODULE__{message: transport_message(reason), details: reason}
  end

  defp message_from_body(%{"message" => message}) when is_binary(message), do: message
  defp message_from_body(%{"error" => error}) when is_binary(error), do: error
  defp message_from_body(body) when is_binary(body) and body != "", do: body
  defp message_from_body(_), do: nil

  defp code_from_body(%{"code" => code}) when is_binary(code), do: code
  defp code_from_body(%{"error" => error, "message" => _}) when is_binary(error), do: error
  defp code_from_body(_), do: nil

  defp transport_message(%{__exception__: true} = exception), do: Exception.message(exception)
  defp transport_message(reason), do: "transport error: #{inspect(reason)}"
end
