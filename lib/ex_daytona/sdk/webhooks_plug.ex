# Compiled only when the host application depends on :plug (declared as an
# optional dependency) — any Phoenix app qualifies. Without plug the SDK
# compiles cleanly and simply doesn't define these modules.
if Code.ensure_loaded?(Plug.Conn) do
  defmodule ExDaytona.Webhooks.Handler do
    @moduledoc """
    Behaviour for `ExDaytona.Webhooks.Plug` event handlers.

        defmodule MyApp.DaytonaWebhooks do
          @behaviour ExDaytona.Webhooks.Handler

          @impl true
          def handle_event(%{"type" => "sandbox.state.updated"} = event, _conn) do
            MyApp.Sandboxes.sync(event["data"])
          end

          def handle_event(_event, _conn), do: :ok
        end

    Return `:ok` (or `{:ok, term}`) to acknowledge the delivery with a
    `204`; return `{:error, term}` (or raise) to answer `500` so the
    provider retries it later.
    """

    @callback handle_event(event :: map() | list() | binary(), conn :: Plug.Conn.t()) ::
                :ok | {:ok, term()} | {:error, term()}
  end

  defmodule ExDaytona.Webhooks.Plug do
    @moduledoc """
    A drop-in endpoint for receiving Daytona webhook deliveries.

    Signature verification needs the **raw** request body, which is a
    notorious footgun behind `Plug.Parsers` (the body is consumed and
    re-encoding breaks the signature). This plug closes the loop: mount it
    **above** `Plug.Parsers` with `:at`, and it reads the raw body,
    verifies the Svix signature via `ExDaytona.Webhooks.verify/4`, invokes
    your handler, and answers with the status the provider's retry logic
    expects — while every other request passes through untouched.

    In a Phoenix endpoint (before `plug Plug.Parsers`):

        plug ExDaytona.Webhooks.Plug,
          at: "/webhooks/daytona",
          secret: {MyApp.Config, :daytona_webhook_secret, []},
          handler: MyApp.DaytonaWebhooks

    In a bare `Plug.Router`, the same options work with `plug ... when
    action`-style mounting, or omit `:at` when the plug terminates a
    dedicated pipeline that only ever sees webhook traffic.

    ## Options

    - `:secret` (required) — the endpoint's signing secret (`whsec_...`):
      a binary, a `{module, function, args}` tuple, or a zero-arity fun
      (both resolved per request, so runtime configuration works)
    - `:handler` (required) — who receives verified events: a module
      implementing `ExDaytona.Webhooks.Handler`, a `{module, function}`
      tuple called as `function(event, conn)`, or a fun of arity 1
      (`event`) or 2 (`event, conn`)
    - `:at` — request path to handle; other paths pass through untouched.
      Omit to handle every request reaching the plug.
    - `:tolerance_seconds` — max timestamp skew (default `300`)
    - `:max_body_bytes` — reject larger deliveries with `413`
      (default `1_048_576`)

    ## Responses

    - `204` — signature valid, handler returned `:ok`/`{:ok, _}`
    - `400` — missing/invalid signature headers, stale timestamp, or
      signature mismatch (the provider will **not** retry a `4xx`)
    - `405` — non-POST request at `:at`
    - `413` — body exceeded `:max_body_bytes`
    - `500` — handler returned `{:error, _}` or raised (the provider
      retries the delivery later)

    This module is compiled only when the optional `:plug` dependency is
    present.
    """

    @behaviour Plug

    require Logger

    alias ExDaytona.Webhooks

    @impl Plug
    def init(opts) do
      %{
        secret: opts |> Keyword.fetch!(:secret) |> validate_secret!(),
        handler: opts |> Keyword.fetch!(:handler) |> validate_handler!(),
        at: Keyword.get(opts, :at),
        tolerance_seconds: Keyword.get(opts, :tolerance_seconds, 300),
        max_body_bytes: Keyword.get(opts, :max_body_bytes, 1_048_576)
      }
    end

    @impl Plug
    def call(conn, %{at: at} = opts) do
      cond do
        is_binary(at) and conn.request_path != at -> conn
        conn.method != "POST" -> respond(conn, 405, "method not allowed")
        true -> handle(conn, opts)
      end
    end

    defp handle(conn, opts) do
      case read_full_body(conn, opts.max_body_bytes, []) do
        {:ok, body, conn} ->
          verify_and_dispatch(conn, body, opts)

        {:error, :too_large, conn} ->
          respond(conn, 413, "payload too large")

        {:error, _reason, conn} ->
          respond(conn, 400, "could not read request body")
      end
    end

    defp verify_and_dispatch(conn, body, opts) do
      secret = resolve_secret(opts.secret)

      case Webhooks.verify(body, conn.req_headers, secret, tolerance_seconds: opts.tolerance_seconds) do
        {:ok, event} ->
          dispatch(conn, event, opts.handler)

        {:error, %ExDaytona.Error{}} ->
          respond(conn, 400, "invalid webhook signature")
      end
    end

    defp dispatch(conn, event, handler) do
      case invoke_handler(handler, event, conn) do
        :ok -> respond(conn, 204, "")
        {:ok, _result} -> respond(conn, 204, "")
        {:error, _reason} -> respond(conn, 500, "webhook handler failed")
      end
    rescue
      exception ->
        Logger.error("ExDaytona.Webhooks.Plug handler raised: " <> Exception.message(exception))
        respond(conn, 500, "webhook handler failed")
    end

    defp invoke_handler(handler, event, _conn) when is_function(handler, 1), do: handler.(event)
    defp invoke_handler(handler, event, conn) when is_function(handler, 2), do: handler.(event, conn)
    defp invoke_handler({module, function}, event, conn), do: apply(module, function, [event, conn])
    defp invoke_handler(module, event, conn) when is_atom(module), do: module.handle_event(event, conn)

    defp resolve_secret(secret) when is_binary(secret), do: secret
    defp resolve_secret({module, function, args}), do: apply(module, function, args)
    defp resolve_secret(fun) when is_function(fun, 0), do: fun.()

    defp read_full_body(conn, max_bytes, acc) do
      case Plug.Conn.read_body(conn, length: max_bytes + 1) do
        {:ok, chunk, conn} ->
          body = IO.iodata_to_binary([acc, chunk])

          if byte_size(body) > max_bytes do
            {:error, :too_large, conn}
          else
            {:ok, body, conn}
          end

        {:more, chunk, conn} ->
          acc = [acc, chunk]

          if IO.iodata_length(acc) > max_bytes do
            {:error, :too_large, conn}
          else
            read_full_body(conn, max_bytes, acc)
          end

        {:error, reason} ->
          {:error, reason, conn}
      end
    end

    defp respond(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(status, body)
      |> Plug.Conn.halt()
    end

    defp validate_secret!(secret)
         when is_binary(secret) or is_function(secret, 0),
         do: secret

    defp validate_secret!({module, function, args} = secret)
         when is_atom(module) and is_atom(function) and is_list(args),
         do: secret

    defp validate_secret!(other) do
      raise ArgumentError,
            ":secret must be a binary, {module, function, args}, or zero-arity fun, " <>
              "got: #{inspect(ExDaytona.Redact.deep(other))}"
    end

    defp validate_handler!(handler)
         when is_function(handler, 1) or is_function(handler, 2),
         do: handler

    defp validate_handler!({module, function} = handler)
         when is_atom(module) and is_atom(function),
         do: handler

    defp validate_handler!(module) when is_atom(module), do: module

    defp validate_handler!(other) do
      raise ArgumentError,
            ":handler must be a module, {module, function}, or fun of arity 1 or 2, " <>
              "got: #{inspect(other)}"
    end
  end
end
