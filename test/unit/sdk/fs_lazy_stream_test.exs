defmodule ExDaytona.FSLazyStreamTest do
  use TestCase, async: true

  # FS.stream!/3 — the lazy Enumerable download. Exercised through the
  # public ExDaytona.Testing doubles (which also dogfoods them).

  alias ExDaytona.Error
  alias ExDaytona.FS
  alias ExDaytona.Testing

  setup do
    {:ok, sandbox: Testing.sandbox()}
  end

  test "enumerates the file's chunks in order", %{sandbox: sandbox} do
    Testing.script_http_stream(chunks: ["aa", "bb", "cc"])

    assert sandbox |> FS.stream!("/workspace/f.bin") |> Enum.to_list() == ["aa", "bb", "cc"]
  end

  test "is lazy: nothing runs until enumeration starts", %{sandbox: sandbox} do
    stream = FS.stream!(sandbox, "/workspace/f.bin")

    # Scripted after the stream was built — only enumeration triggers I/O
    Testing.script_http_stream(chunks: ["late"])

    assert Enum.to_list(stream) == ["late"]
  end

  test "composes with Stream and collects into files", %{sandbox: sandbox} do
    Testing.script_http_stream(chunks: ["hello ", "world"])

    joined =
      sandbox
      |> FS.stream!("/workspace/f.txt")
      |> Stream.map(&String.upcase/1)
      |> Enum.join()

    assert joined == "HELLO WORLD"
  end

  test "halting early cancels the transfer", %{sandbox: sandbox} do
    Testing.script_http_stream(chunks: List.duplicate("x", 50))

    assert sandbox |> FS.stream!("/workspace/big.bin") |> Enum.take(2) == ["x", "x"]
  end

  test "a non-2xx response raises the ExDaytona.Error", %{sandbox: sandbox} do
    Testing.script_http_stream(
      status: 404,
      chunks: [JSON.encode!(%{message: "file not found"})]
    )

    assert_raise Error, ~r/file not found/, fn ->
      sandbox |> FS.stream!("/workspace/missing") |> Enum.to_list()
    end
  end

  test "a transport failure raises the ExDaytona.Error", %{sandbox: sandbox} do
    Testing.script_http_stream(chunks: ["partial"], error: :closed)

    assert_raise Error, fn ->
      sandbox |> FS.stream!("/workspace/f.bin") |> Enum.to_list()
    end
  end

  test "max_bytes aborts the stream", %{sandbox: sandbox} do
    Testing.script_http_stream(chunks: ["aaaa", "bbbb", "cccc"])

    assert_raise Error, ~r/max_bytes/, fn ->
      sandbox |> FS.stream!("/workspace/f.bin", max_bytes: 6) |> Enum.to_list()
    end
  end
end
