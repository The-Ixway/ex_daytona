defmodule ExDaytona.LogStreamTest do
  use TestCase, async: true

  alias ExDaytona.Client
  alias ExDaytona.Error
  alias ExDaytona.LogStream
  alias ExDaytona.Model
  alias ExDaytona.Session

  @out <<0x01, 0x01, 0x01>>
  @err <<0x02, 0x02, 0x02>>

  defp open!(opts) do
    {ws_opts, opts} = Keyword.split(opts, [:frames, :frame_delay, :close_reason, :hold_open, :connect])
    FakeTransports.script_ws(ws_opts)

    LogStream.open(
      "http://fake/logs",
      "dtn_test",
      [ws_mod: FakeTransports.WS, idle_timeout: :infinity] ++ opts
    )
  end

  describe "demultiplexing" do
    test "separates stdout and stderr preserving arrival order" do
      {:ok, stream} =
        open!(
          frames: [
            {:binary, @out <> "out-1" <> @err <> "err-1" <> @out <> "out-2"}
          ]
        )

      assert {:ok, {:stdout, "out-1"}} = LogStream.next(stream)
      assert {:ok, {:stderr, "err-1"}} = LogStream.next(stream)
      assert {:ok, {:stdout, "out-2"}} = LogStream.next(stream)
      assert {:closed, :normal} = LogStream.next(stream)
    end

    test "handles markers fragmented across websocket frames" do
      {:ok, stream} =
        open!(
          frames: [
            {:binary, @out <> "hel"},
            # marker split: one byte at the end of a frame, two at the start of the next
            {:binary, "lo" <> <<0x02>>},
            {:binary, <<0x02, 0x02>> <> "warn"}
          ]
        )

      assert {:ok, collected} = LogStream.collect(stream)
      assert collected.stdout == "hello"
      assert collected.stderr == "warn"
      assert collected.closed == :normal
    end

    test "text frames and split payloads work; pre-marker bytes are dropped" do
      {:ok, stream} =
        open!(
          frames: [
            # bytes before any channel marker have no destination
            {:binary, "noise"},
            {:text, @out <> "part1-"},
            {:text, "part2"}
          ]
        )

      assert {:ok, %{stdout: "part1-part2", stderr: ""}} = LogStream.collect(stream)
    end

    test "malformed marker-only frames do not crash the stream" do
      {:ok, stream} =
        open!(frames: [{:binary, @out}, {:binary, @err}, {:binary, @out <> "ok"}])

      assert {:ok, %{stdout: "ok", stderr: ""}} = LogStream.collect(stream)
    end
  end

  describe "bounds" do
    test "byte-buffer overflow closes with an explicit error" do
      {:ok, stream} =
        open!(
          frames: [
            {:binary, @out <> String.duplicate("x", 600)},
            {:binary, String.duplicate("y", 600)}
          ],
          hold_open: true,
          max_buffer_bytes: 1_000
        )

      # No consumer pulling: the second frame overflows the 1KB bound
      assert {:closed, {:error, %Error{code: "OVERFLOW"}}} = LogStream.next(stream, 2_000)
    end

    test "frame-size overflow closes with an explicit error" do
      {:ok, stream} =
        open!(
          frames: [{:binary, @out <> String.duplicate("z", 2_000)}],
          hold_open: true,
          max_frame_bytes: 1_000
        )

      assert {:closed, {:error, %Error{code: "FRAME_TOO_LARGE"}}} = LogStream.next(stream, 2_000)
    end

    test "a burst within bounds drains fully to a slow consumer" do
      frames = for i <- 1..50, do: {:binary, @out <> "chunk-#{i}|"}

      {:ok, stream} = open!(frames: frames, max_buffer_bytes: 100_000, max_frames: 1_000)

      Process.sleep(50)

      collected =
        Enum.reduce_while(1..100, [], fn _, acc ->
          Process.sleep(1)

          case LogStream.next(stream, 1_000) do
            {:ok, {:stdout, bytes}} -> {:cont, [bytes | acc]}
            {:closed, :normal} -> {:halt, acc}
          end
        end)

      assert collected |> Enum.reverse() |> Enum.join() =~ "chunk-1|"
      assert Enum.join(collected) =~ "chunk-50|"
    end
  end

  describe "lifecycle" do
    test "owner death shuts the stream down" do
      parent = self()

      owner =
        spawn(fn ->
          receive do
            :die -> :ok
          end
        end)

      FakeTransports.script_ws(frames: [], hold_open: true)

      {:ok, stream} =
        LogStream.open("http://fake/logs", "k",
          ws_mod: FakeTransports.WS,
          owner: owner,
          idle_timeout: :infinity
        )

      ref = Process.monitor(stream)
      send(owner, :die)

      assert_receive {:DOWN, ^ref, :process, ^stream, _}, 2_000
      _ = parent
    end

    test "close/1 is idempotent and next after close reports closed" do
      {:ok, stream} = open!(frames: [{:binary, @out <> "data"}], hold_open: true)

      assert {:ok, {:stdout, "data"}} = LogStream.next(stream, 2_000)
      assert :ok = LogStream.close(stream)
      assert :ok = LogStream.close(stream)
      assert {:closed, :normal} = LogStream.next(stream, 1_000)
      assert {:closed, :normal} = LogStream.next(stream, 1_000)
    end

    test "disconnect before, during, and after output" do
      # before any output
      {:ok, s1} = open!(frames: [], close_reason: {:error, :closed})
      assert {:closed, {:error, %Error{}}} = LogStream.next(s1, 2_000)

      # during output: queued events drain first, then the error surfaces
      {:ok, s2} =
        open!(frames: [{:binary, @out <> "partial"}], close_reason: {:error, :closed})

      assert {:ok, {:stdout, "partial"}} = LogStream.next(s2, 2_000)
      assert {:closed, {:error, %Error{}}} = LogStream.next(s2, 2_000)

      # after final output with a clean close
      {:ok, s3} = open!(frames: [{:binary, @out <> "done"}])
      assert {:ok, %{stdout: "done", closed: :normal}} = LogStream.collect(s3)
    end

    test "upgrade failure surfaces from open/3" do
      assert {:error, %Error{message: message}} =
               open!(connect: {:error, %Error{message: "upgrade refused"}})

      assert message =~ "upgrade refused"
    end

    test "no reconnect after close: the stream stays closed" do
      {:ok, stream} = open!(frames: [{:binary, @out <> "once"}])

      assert {:ok, %{stdout: "once"}} = LogStream.collect(stream)

      # Repeated polls stay closed — nothing reconnects or replays
      for _ <- 1..3 do
        assert {:closed, :normal} = LogStream.next(stream, 100)
      end
    end
  end

  describe "timeouts" do
    test "idle timeout closes the stream with an explicit error" do
      FakeTransports.script_ws(frames: [], hold_open: true)

      {:ok, stream} =
        LogStream.open("http://fake/logs", "k",
          ws_mod: FakeTransports.WS,
          idle_timeout: 50
        )

      assert {:closed, {:error, %Error{code: "IDLE_TIMEOUT"}}} = LogStream.next(stream, 2_000)
    end

    test "overall timeout fires even while frames keep arriving" do
      frames = for i <- 1..100, do: {:binary, @out <> "t#{i}"}
      FakeTransports.script_ws(frames: frames, frame_delay: 5, hold_open: true)

      {:ok, stream} =
        LogStream.open("http://fake/logs", "k",
          ws_mod: FakeTransports.WS,
          idle_timeout: :infinity,
          overall_timeout: 60
        )

      # Drain until the deadline error surfaces
      result =
        Enum.reduce_while(1..200, nil, fn _, _ ->
          case LogStream.next(stream, 1_000) do
            {:ok, _} -> {:cont, nil}
            {:closed, reason} -> {:halt, reason}
          end
        end)

      assert {:error, %Error{code: "DEADLINE"}} = result
    end

    test "next/2 times out while the stream is live without closing it" do
      {:ok, stream} = open!(frames: [], hold_open: true)

      assert {:error, %Error{message: message}} = LogStream.next(stream, 50)
      assert message =~ "timed out"

      # stream is still usable
      assert Process.alive?(stream)
    end
  end

  describe "Session.open_log_stream/3" do
    test "builds the follow URL and honors the client's ws transport" do
      {:ok, client} =
        Client.new(api_key: "dtn_test", transports: [websocket: FakeTransports.WS])

      sandbox = %ExDaytona.Sandbox{
        client: client,
        info: %Model.Sandbox{id: "sb-1", toolboxProxyUrl: "http://fake"}
      }

      session = %Session{sandbox: sandbox, id: "s-1"}

      FakeTransports.script_ws(frames: [{:binary, @out <> "from-session"}])

      assert {:ok, stream} =
               Session.open_log_stream(session, "cmd-1", idle_timeout: :infinity)

      assert {:ok, %{stdout: "from-session"}} = LogStream.collect(stream)
    end
  end
end
