defmodule ExDaytona.Git do
  @moduledoc """
  Git operations inside a sandbox.

  Every function takes the sandbox and the repository path inside it, and
  returns `{:ok, value}` / `:ok` or `{:error, %ExDaytona.Error{}}`:

      :ok = ExDaytona.Git.clone(sandbox, "https://github.com/org/repo.git", "/tmp/repo")

      {:ok, status} = ExDaytona.Git.status(sandbox, "/tmp/repo")
      {:ok, %{branches: branches, current: "main"}} = ExDaytona.Git.branches(sandbox, "/tmp/repo")

      :ok = ExDaytona.Git.create_branch(sandbox, "/tmp/repo", "feature/x")
      :ok = ExDaytona.Git.checkout(sandbox, "/tmp/repo", "feature/x")
      :ok = ExDaytona.Git.add(sandbox, "/tmp/repo", ["README.md"])

      {:ok, %{hash: hash}} =
        ExDaytona.Git.commit(sandbox, "/tmp/repo", "docs: update readme",
          author: "Dev",
          email: "dev@example.com"
        )

  Authenticated operations (`clone/4`, `push/3`, `pull/3`) accept
  `:username`/`:password` — pass a token as the password for HTTPS
  remotes.
  """

  alias ExDaytona.Api
  alias ExDaytona.Error
  alias ExDaytona.Model
  alias ExDaytona.Sandbox

  @doc """
  Clone `url` into `path` inside the sandbox.

  Options: `:branch`, `:commit_id`, `:depth`, `:username`, `:password`.
  """
  @spec clone(Sandbox.t(), String.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def clone(%Sandbox{} = sandbox, url, path, opts \\ [])
      when is_binary(url) and is_binary(path) do
    request = %Model.GitCloneRequest{
      url: url,
      path: path,
      branch: opts[:branch],
      commit_id: opts[:commit_id],
      depth: opts[:depth],
      username: opts[:username],
      password: opts[:password]
    }

    run(sandbox, &Api.Git.clone_repository(&1, request, response: :full))
  end

  @doc """
  The repository's status as an `ExDaytona.Model.GitStatus`
  (current branch, ahead/behind, per-file status).
  """
  @spec status(Sandbox.t(), String.t()) :: {:ok, Model.GitStatus.t()} | {:error, Error.t()}
  def status(%Sandbox{} = sandbox, path) when is_binary(path) do
    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox) do
      Error.normalize(Api.Git.get_status(conn, path, response: :full))
    end
  end

  @doc """
  The repository's branches: `{:ok, %{branches: [...], current: branch}}`.
  """
  @spec branches(Sandbox.t(), String.t()) ::
          {:ok, %{branches: [String.t()], current: String.t() | nil}} | {:error, Error.t()}
  def branches(%Sandbox{} = sandbox, path) when is_binary(path) do
    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox),
         {:ok, %Model.ListBranchResponse{branches: branches, current: current}} <-
           Error.normalize(Api.Git.list_branches(conn, path, response: :full)) do
      {:ok, %{branches: branches || [], current: current}}
    end
  end

  @doc """
  Create branch `name`. Returns `:ok`.
  """
  @spec create_branch(Sandbox.t(), String.t(), String.t()) :: :ok | {:error, Error.t()}
  def create_branch(%Sandbox{} = sandbox, path, name)
      when is_binary(path) and is_binary(name) do
    run(sandbox, &Api.Git.create_branch(&1, %Model.GitBranchRequest{path: path, name: name}, response: :full))
  end

  @doc """
  Check out `branch`. Returns `:ok`.
  """
  @spec checkout(Sandbox.t(), String.t(), String.t()) :: :ok | {:error, Error.t()}
  def checkout(%Sandbox{} = sandbox, path, branch)
      when is_binary(path) and is_binary(branch) do
    run(
      sandbox,
      &Api.Git.checkout_branch(&1, %Model.GitCheckoutRequest{path: path, branch: branch}, response: :full)
    )
  end

  @doc """
  Stage `files` (a list of paths relative to the repository). Returns
  `:ok`.
  """
  @spec add(Sandbox.t(), String.t(), [String.t()]) :: :ok | {:error, Error.t()}
  def add(%Sandbox{} = sandbox, path, files) when is_binary(path) and is_list(files) do
    run(sandbox, &Api.Git.add_files(&1, %Model.GitAddRequest{path: path, files: files}, response: :full))
  end

  @doc """
  Commit staged changes. Returns `{:ok, %{hash: sha}}`.

  Required options: `:author`, `:email`. Optional: `:allow_empty`.
  """
  @spec commit(Sandbox.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{hash: String.t() | nil}} | {:error, Error.t()}
  def commit(%Sandbox{} = sandbox, path, message, opts)
      when is_binary(path) and is_binary(message) do
    with {:ok, author} <- require_opt(opts, :author),
         {:ok, email} <- require_opt(opts, :email),
         {:ok, conn} <- Sandbox.toolbox_conn(sandbox),
         {:ok, %Model.GitCommitResponse{hash: hash}} <-
           Error.normalize(
             Api.Git.commit_changes(
               conn,
               %Model.GitCommitRequest{
                 path: path,
                 message: message,
                 author: author,
                 email: email,
                 allow_empty: opts[:allow_empty]
               },
               response: :full
             )
           ) do
      {:ok, %{hash: hash}}
    end
  end

  @doc """
  Push commits to the remote. Returns `:ok`.

  Options: `:remote`, `:branch`, `:set_upstream`, `:username`,
  `:password`.
  """
  @spec push(Sandbox.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def push(%Sandbox{} = sandbox, path, opts \\ []) when is_binary(path) do
    request = %Model.GitPushRequest{
      path: path,
      remote: opts[:remote],
      branch: opts[:branch],
      set_upstream: opts[:set_upstream],
      username: opts[:username],
      password: opts[:password]
    }

    run(sandbox, &Api.Git.push_changes(&1, request, response: :full))
  end

  @doc """
  Pull from the remote. Returns `:ok`.

  Options: `:remote`, `:branch`, `:username`, `:password`.
  """
  @spec pull(Sandbox.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def pull(%Sandbox{} = sandbox, path, opts \\ []) when is_binary(path) do
    request = %Model.GitPullRequest{
      path: path,
      remote: opts[:remote],
      branch: opts[:branch],
      username: opts[:username],
      password: opts[:password]
    }

    run(sandbox, &Api.Git.pull_changes(&1, request, response: :full))
  end

  @doc """
  The repository's commit history as `ExDaytona.Model.GitCommitInfo`
  structs (newest first).
  """
  @spec history(Sandbox.t(), String.t()) ::
          {:ok, [Model.GitCommitInfo.t()]} | {:error, Error.t()}
  def history(%Sandbox{} = sandbox, path) when is_binary(path) do
    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox),
         {:ok, commits} <- Error.normalize(Api.Git.get_commit_history(conn, path, response: :full)) do
      {:ok, List.wrap(commits)}
    end
  end

  # Runs an operation whose success value carries no information (raw env
  # passthrough) and collapses it to :ok.
  defp run(sandbox, api_fn) do
    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox),
         {:ok, _} <- Error.normalize(api_fn.(conn)) do
      :ok
    end
  end

  defp require_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:error, %Error{message: "commit requires the #{inspect(key)} option"}}
    end
  end
end
