# herdr-plugins

A collection of [herdr](https://herdr.dev) plugins, one plugin per
subdirectory. herdr installs and links subdirectories directly, so no build
orchestration is needed at the repo level.

| Plugin | Description |
|--------|-------------|
| [workspace-auto-rename](workspace-auto-rename/) | Renames workspaces from a configurable template (`{branch}`, `{repo-name}`, `{agent-kind}`, ...) as they are created |

## Install a plugin

From GitHub (once published):

```sh
herdr plugin install lucaspimentel/herdr-plugins/<plugin-name>
```

From a local checkout (no build step):

```sh
herdr plugin link /path/to/herdr-plugins/<plugin-name>
```

See each plugin's README for configuration and usage.
