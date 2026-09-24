# workspace-auto-rename

A [herdr](https://herdr.dev) plugin that renames workspaces from a
configurable template (for example `{repo-name}/{branch}`) as they are
created. Part of the [herdr-plugins](..) collection: each subdirectory of
that repo is a standalone plugin.

The plugin is **opt-in**: with no `config.toml` in the plugin config
directory it does nothing and workspaces keep their herdr-assigned names.

## How it works

- `worktree.created` / `worktree.opened`: renames worktree-backed
  workspaces; branch and repo name are known at event time.
- `workspace.created`: renames plain workspaces; with no branch available it
  falls back to `template-no-git` or a git lookup in the workspace cwd.
- `pane.agent_detected`: fills `{agent-kind}` for workspaces that still
  carry their birth label (gated by `rename-on-agent-detect`).
- `[[startup]]`: re-applies the template to existing workspaces after a
  session restore (gated by `adopt-existing`).
- A manual action, "Re-apply rename template", re-renders the current
  workspace on demand.

The plugin never hooks `workspace.updated` or `workspace.renamed`: renaming
from those would risk event churn and recursion.

## Requirements

- herdr >= 0.9.1
- bash, jq, git, sed
- `gh` (GitHub CLI), optional: only needed when the template uses `{pr}` and
  the branch name does not already encode the PR number; must be
  authenticated against the repository host
- Linux or macOS (the hooks are bash scripts; Windows is not supported)

## Install

Local checkout (no build step):

```sh
herdr plugin link /path/to/herdr-plugins/workspace-auto-rename
```

From GitHub (once published):

```sh
herdr plugin install lucaspimentel/herdr-plugins/workspace-auto-rename
```

## Configure

Copy the example into the plugin's own config directory:

```sh
herdr plugin config-dir workspace-auto-rename
cp config.example.toml <that directory>/config.toml
```

Then edit `template`. Until `template` is set, the plugin stays inert.

| Key                      | Default            | Meaning |
|--------------------------|--------------------|---------|
| `template`               | (none; inert)      | Template applied when a branch is known |
| `template-no-git`        | `{cwd-basename}`   | Template used when no git branch is known |
| `[repo-alias]`           | (empty)            | TOML table mapping repo names to display strings for `{repo-name}`; unmapped repos keep their full name |
| `only-rename-unmodified` | `true`             | Never rename a workspace whose label was changed after creation; set `false` to always re-apply |
| `rename-on-agent-detect` | `true`             | Also rename when an agent is detected in a workspace still carrying its birth label |
| `adopt-existing`         | `true`             | On startup and agent detection, rename never-before-seen workspaces; set `false` to only record their labels, protecting names that predate the install |

## Template variables

| Variable              | Source |
|-----------------------|--------|
| `{branch}`            | Event payload, `herdr worktree list --workspace <id>`, or `git rev-parse --abbrev-ref HEAD` in the workspace cwd |
| `{repo-name}`         | Event/context worktree info, or the git toplevel basename |
| `{cwd-basename}`      | Workspace cwd basename (worktree path, else agent list) |
| `{worktree-basename}` | Worktree checkout path basename |
| `{agent-kind}`        | Agent detection event, focused pane agent, or `herdr agent list` |
| `{agent-name}`        | Best-effort; usually empty (herdr exposes no display-name field in `agent list`) |
| `{pr}`                | PR number for the branch, rendered as a unit (`#1234`, or empty when none): branch-name pattern (`pr-123`, `pr/123`, `pr123`, `123-fix`) first, then `gh pr list --head` when `gh` is installed; cached per repo and branch, including misses |
| `{workspace-id}`      | Workspace id, e.g. `w2` |
| `{workspace-number}`  | Workspace number |
| `{current-label}`     | The label at event time |

Unmatched placeholders render as empty strings. After substitution the label
is normalized: duplicate slashes collapse to one, leading/trailing slashes
are stripped, and the result is clamped to herdr's 80-character label cap.

## Rename guard

The plugin records, per workspace, the label herdr assigned at creation
(`birth`) and the last label it applied (`applied`), in the plugin state
directory. A workspace is renamed only when its current label equals one of
those two, which means manual renames made in the TUI are never overwritten.
Workspaces with no recorded birth label (created before the plugin was
linked, or before state existed) are handled per `adopt-existing`.

Note the corollary: the first startup pass with `adopt-existing = true` may
rename workspaces whose names predate the install. Set it to `false` first
if that is a concern.

## Debugging

Hook invocations (exit code plus capped stdout/stderr) are visible in:

```sh
herdr plugin log list --plugin workspace-auto-rename
```

## Development

```sh
tests/run-tests.sh   # offline unit + scenario tests against a stub CLI
shellcheck -x hooks/*.sh tests/*
```

`tests/run-tests.sh` never talks to a live herdr server: all CLI traffic
goes through `tests/fake-herdr` via `HERDR_BIN_PATH`.

### Known limitations

- Whether creation events replay during server restore is unverified; the
  `[[startup]]` hook is the documented re-apply mechanism.
- `{agent-name}` is best-effort and usually renders empty.
- The first `[[startup]]` pass with `{pr}` in the template may perform one
  `gh` lookup per distinct repo and branch; results are cached in the plugin
  state directory afterward, including branches with no PR.
