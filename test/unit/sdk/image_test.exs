defmodule ExDaytona.ImageTest do
  use TestCase, async: true

  alias ExDaytona.Image
  alias ExDaytona.Model

  describe "the DSL" do
    test "renders instructions in order" do
      dockerfile =
        Image.from("ubuntu:22.04")
        |> Image.run("apt-get update && apt-get install -y curl")
        |> Image.env(%{"LANG" => "C.UTF-8", "APP_ENV" => "prod"})
        |> Image.workdir("/workspace")
        |> Image.user("daytona")
        |> Image.label("org.opencontainers.image.source", "https://example.com")
        |> Image.expose(4000)
        |> Image.entrypoint(["/bin/sh", "-c"])
        |> Image.cmd(["echo", "hello world"])
        |> Image.instruction("HEALTHCHECK NONE")
        |> Image.dockerfile()

      assert dockerfile == """
             FROM ubuntu:22.04
             RUN apt-get update && apt-get install -y curl
             ENV APP_ENV="prod"
             ENV LANG="C.UTF-8"
             WORKDIR /workspace
             USER daytona
             LABEL org.opencontainers.image.source="https://example.com"
             EXPOSE 4000
             ENTRYPOINT ["/bin/sh","-c"]
             CMD ["echo","hello world"]
             HEALTHCHECK NONE
             """
    end

    test "escapes double quotes in env and label values" do
      dockerfile =
        Image.from("alpine")
        |> Image.env(%{"MOTD" => ~s(say "hi")})
        |> Image.dockerfile()

      assert dockerfile =~ ~s(ENV MOTD="say \\"hi\\"")
    end

    test "raw/1 wraps a Dockerfile verbatim and rejects appends" do
      image = Image.raw("FROM scratch\n")

      assert Image.dockerfile(image) == "FROM scratch\n"

      assert_raise ArgumentError, ~r/raw Dockerfile/, fn ->
        Image.run(image, "echo nope")
      end
    end
  end

  describe "local build contexts" do
    setup do
      dir = Path.join(System.tmp_dir!(), "ex_daytona_img_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "src"))
      File.write!(Path.join(dir, "mix.exs"), "defmodule P.MixProject do\nend\n")
      File.write!(Path.join(dir, "src/app.ex"), "defmodule App do\nend\n")
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "add_local_file/3 emits a COPY and records the context", %{dir: dir} do
      file = Path.join(dir, "mix.exs")
      archive_path = ExDaytona.ObjectStorage.archive_base_path(file)

      image = Image.from("alpine") |> Image.add_local_file(file, "/workspace/mix.exs")

      assert Image.dockerfile(image) =~ "COPY #{archive_path} /workspace/mix.exs"

      assert [%{source_path: ^file, archive_path: ^archive_path}] = Image.contexts(image)
    end

    test "a trailing slash on remote_path keeps the file name", %{dir: dir} do
      file = Path.join(dir, "mix.exs")

      image = Image.from("alpine") |> Image.add_local_file(file, "/workspace/")

      assert Image.dockerfile(image) =~ " /workspace/mix.exs\n"
    end

    test "add_local_dir/3 records the directory context", %{dir: dir} do
      src = Path.join(dir, "src")

      image = Image.from("alpine") |> Image.add_local_dir(src, "/workspace/src")

      assert [%{source_path: ^src}] = Image.contexts(image)
      assert Image.dockerfile(image) =~ " /workspace/src\n"
    end

    test "contexts preserve declaration order", %{dir: dir} do
      image =
        Image.from("alpine")
        |> Image.add_local_file(Path.join(dir, "mix.exs"), "/w/mix.exs")
        |> Image.add_local_dir(Path.join(dir, "src"), "/w/src")

      assert [%{source_path: first}, %{source_path: second}] = Image.contexts(image)
      assert String.ends_with?(first, "mix.exs")
      assert String.ends_with?(second, "src")
    end

    test "validates paths at definition time", %{dir: dir} do
      assert_raise ArgumentError, ~r/does not exist/, fn ->
        Image.from("alpine") |> Image.add_local_file(Path.join(dir, "nope.txt"), "/w/")
      end

      assert_raise ArgumentError, ~r/use add_local_dir/, fn ->
        Image.from("alpine") |> Image.add_local_file(Path.join(dir, "src"), "/w/src")
      end

      assert_raise ArgumentError, ~r/use add_local_file/, fn ->
        Image.from("alpine") |> Image.add_local_dir(Path.join(dir, "mix.exs"), "/w/")
      end
    end
  end

  describe "build_info/1" do
    test "produces a CreateBuildInfo from images and plain strings" do
      image = Image.from("alpine") |> Image.run("apk add git")

      assert %Model.CreateBuildInfo{dockerfileContent: "FROM alpine\nRUN apk add git\n"} =
               Image.build_info(image)

      assert %Model.CreateBuildInfo{dockerfileContent: "FROM scratch\n"} =
               Image.build_info("FROM scratch\n")
    end
  end
end
