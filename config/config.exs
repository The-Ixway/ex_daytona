import Config

# This file is responsible for configuring your application at compile-time.
# Configuration from this file will be compiled into your application and
# can NOT be changed at runtime.
#
# For runtime configuration, see config/runtime.exs

# Configure logging
config :logger,
  level: :info,
  compile_time_purge_matching: [
    [level_lower_than: :info]
  ]

# Release automation via conventional commits (dev-only dependency, so only
# configure it in dev — configuring an absent application is an error under
# `mix check`'s warnings-as-errors).
# `mix git_ops.release` bumps @version in mix.exs, updates CHANGELOG.md, and
# creates the version tag. The repository URL is filled in by scripts/setup.sh.
if config_env() == :dev do
  config :git_ops,
    mix_project: Mix.Project.get!(),
    changelog_file: "CHANGELOG.md",
    repository_url: "{{GIT_REPO_URL}}",
    manage_mix_version?: true,
    manage_readme_version: false,
    version_tag_prefix: "v"
end

# Import environment specific config
import_config "#{config_env()}.exs"
