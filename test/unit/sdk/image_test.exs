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
