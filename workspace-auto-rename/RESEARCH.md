# Research: Auto-renaming herdr workspaces from a template (herdr 0.9.1)
Research only. Every CLI claim below was verified against the installed binary
(`/home/linuxbrew/.linuxbrew/bin/herdr`, version 0.9.1) with read-only commands.
Upstream claims cite the official docs at herdr.dev and the tagged source at
`github.com/herdrdev/herdr` (v0.9.1), whose raw doc sources are linked from
<https://herdr.dev/llms.txt>. The local reference plugin is
`/home/lucas/source/smarzban/herdr-file-viewer` (GitHub: smarzban/herdr-file-viewer).

Note: `web_fetch` was unavailable in this session (permission gating); official
pages were retrieved with `curl` from the raw doc sources listed in
`https://herdr.dev/llms.txt`, which serve the exact documented revision.

---

## 1. Executive summary

**Feasible: yes, cleanly, with an `[[events]]` hook plugin.** herdr 0.9.1 has a
first-class plugin event system: a `[[events]]` section in `herdr-plugin.toml`
subscribes the plugin to lifecycle events such as `workspace.created`,
`worktree.created`, and `worktree.opened` (22 hookable events total). On each
event, herdr spawns the hook command with the full event envelope in
`HERDR_PLUGIN_EVENT_JSON` and a context object (workspace id, label, cwd,
worktree info, focused agent) in `HERDR_PLUGIN_CONTEXT_JSON`. The hook computes
a label from a user-editable TOML template and calls
`herdr workspace rename <workspace_id> <label>` (verified: `herdr workspace
rename <WORKSPACE_ID> <LABEL>...`). There is **no native naming-template config
key** in 0.9.1 stable or preview (checked the full config reference), so a
plugin is the right mechanism. The main design care point: hook
`workspace.created` / `worktree.created` / `worktree.opened` (creation-time
events that carry the data you need) rather than `workspace.updated`, and skip
renaming when the current label already matches the template to avoid churn.

---

## 2. Plugin system overview

### 2.1 CLI surface (verified against installed 0.9.1)

`herdr plugin --help` lists: `install`, `uninstall`, `link`, `unlink`,
`enable`, `disable`, `list`, `config-dir`, `action`, `log` (alias `logs`),
`pane`.

Verified help text (abridged):

```
herdr plugin install [OPTIONS] <OWNER/REPO[/SUBDIR]>   # --ref <REF>, -y/--yes
herdr plugin link [OPTIONS] <PATH>                     # --disabled / --enabled
herdr plugin list [--plugin <ID>] [--json]
herdr plugin config-dir <PLUGIN_ID>
herdr plugin action [list|invoke]                      # invoke: <ACTION_ID>, --plugin <ID>
herdr plugin log list
```

- GitHub installs accept **only** `owner/repo[/subdir]` shorthand and clone
  with git; there is no `plugin update` in v1, reinstall to refresh
  (https://herdr.dev/docs/plugins/, "Install and link").
- `herdr plugin list --json` (live output) returns
  `{"id":"cli:plugin","result":{"plugins":[...]}}` where each plugin has
  `plugin_id`, `plugin_root`, `manifest_path`, `managed_path`, `enabled`,
  `version`, `min_herdr_version`, `platforms`, `actions[]`, `panes[]`,
  `source` (repo/owner/kind/resolved_commit), `installed_unix_ms`, `build`.
- Install location (source: `src/plugin_paths.rs` in herdrdev/herdr@v0.9.1):
  - Managed GitHub checkouts: `<config_dir>/plugins/github/<component>`
    (Linux config dir: `~/.config/herdr/`).
  - Per-plugin config dir: `<config_dir>/plugins/config/<component>`;
    verified live: `herdr plugin config-dir herdr-file-viewer` printed
    `/home/lucas/.config/herdr/plugins/config/herdr-file-viewer`.
  - Per-plugin state dir: `<state_dir>/plugins/<component>`.
  - `HERDR_PLUGIN_ROOT` (read-only managed checkout), `HERDR_PLUGIN_CONFIG_DIR`,
    and `HERDR_PLUGIN_STATE_DIR` are injected into every plugin command
    (https://herdr.dev/docs/plugins/, "Commands and environment").

### 2.2 Loading and registration

- A plugin is a directory with `herdr-plugin.toml` plus commands. "Herdr
  validates the manifest, injects runtime context, starts the declared
  commands, and records logs" (https://herdr.dev/docs/plugins/, intro).
- `plugin install` runs `[[build]]` commands at install time (after a preview);
  `plugin link` does **not** run build commands (same page, "Build commands").
- Plugins are global to the user and available in every session; install/link
  work with no server running (same page).
- Manifest validation is done at link/load; unknown `[[events]]` names produce
  a **non-fatal warning** surfaced via `plugin.list`
  (`src/app/api/plugins/manifest.rs` `validate_event_names`, and
  `src/api/schema/plugins.rs` `warnings` doc: "Non-fatal; the entry is kept
  and surfaced by plugin.list").
- There is no plugin SDK: "The entire Herdr CLI is the plugin API"; call back
  via `HERDR_BIN_PATH` for portability (Unix socket vs Windows named pipe)
  (https://herdr.dev/docs/plugins/, intro + "Commands and environment").

### 2.3 Manifest schema (0.9.1)

Verified from the official docs (https://herdr.dev/docs/plugins/, "Manifest")
and cross-checked against `src/api/schema/plugins.rs` and
`src/app/api/plugins/manifest.rs` (herdrdev/herdr@v0.9.1):

| Section | Fields |
|---|---|
| top-level (required) | `id`, `name`, `version`, `min_herdr_version` |
| top-level (optional) | `description`, `platforms` (`["linux","macos","windows"]`) |
| `[[build]]` | `command` (argv array), optional `platforms` |
| `[[startup]]` | `command`, optional `platforms` |
| `[[actions]]` | `id`, `title`, `command`, optional `contexts`, `description`, `platforms` |
| `[[events]]` | `on` (event name), `command` (argv array), optional `platforms` |
| `[[panes]]` | `id`, `title`, `command`, optional `placement` (`overlay`/`popup`/`split`/`tab`/`zoomed`), `width`, `height`, `description`, `platforms` |
| `[[link_handlers]]` | `id`, `title`, `pattern` (Rust regex), `action` |

- `command` values are argv arrays; no shell expansion unless you start one
  yourself (docs, "Manifest").
- `min_herdr_version` is enforced: herdr refuses to link/install a plugin whose
  minimum is newer than the binary (docs, "Manifest").
- Top-level `platforms` optional for local plugins (links with a warning);
  item-level `platforms` override the top-level list (docs, "Manifest").
- The reference plugin confirms all of this in practice
  (`/home/lucas/source/smarzban/herdr-file-viewer/herdr-plugin.toml:40-96`):
  per-platform `[[build]]` entries, `placement = "split"` pane, actions with
  per-item `platforms`, and it deliberately has **no** `[[events]]` section
  (its header, lines 3-5, and the `[[actions]]` comment, lines 53-55, state
  this: "there are no event hooks and no automatic invocation (AC-N4)").
  Contrary to what the task brief suggested, the official 0.9.1 docs and
  source **do** define `[[events]]`; the reference plugin simply does not use
  them. Plugins cannot declare config keys inside herdr own `config.toml`;
  `herdr config --help` only offers `check` and `reset-keys` (verified live).

---

## 3. Event/trigger surface relevant to workspace rename

### 3.1 Hookable events (exact list, 0.9.1)

`[[events]] on` accepts exactly these names
(`src/api/schema/events.rs:286-309`, `PLUGIN_HOOK_EVENT_KINDS`; the test at
lines 351-358 confirms high-volume events are excluded):

```
workspace.created      workspace.updated      workspace.closed
workspace.renamed      workspace.moved        workspace.reordered
workspace.focused
worktree.created       worktree.opened        worktree.removed
tab.created            tab.closed             tab.renamed
tab.moved              tab.focused
pane.created           pane.closed            pane.focused
pane.moved             pane.exited
pane.agent_detected    pane.agent_status_changed
```

Excluded (not hookable): `pane.output_changed`, `layout.updated`,
`workspace.metadata_updated`, `pane.updated`, `pane.output_matched`,
`pane.scroll_changed` (events.rs test + docs).

### 3.2 Event delivery mechanics

- On each matching event herdr spawns the hook command with cwd = plugin root,
  env = normal runtime env **plus**:
  - `HERDR_PLUGIN_EVENT` = event name (e.g. `workspace.created`)
  - `HERDR_PLUGIN_EVENT_JSON` = the full event envelope, serialized
  - `HERDR_PLUGIN_CONTEXT_JSON` = invocation context object
  - plus `HERDR_SOCKET_PATH`, `HERDR_BIN_PATH`, `HERDR_ENV=1`,
    `HERDR_PLUGIN_ID`, `HERDR_PLUGIN_ROOT`, `HERDR_PLUGIN_CONFIG_DIR`,
    `HERDR_PLUGIN_STATE_DIR`, and when available `HERDR_WORKSPACE_ID`,
    `HERDR_TAB_ID`, `HERDR_PANE_ID`
  (https://herdr.dev/docs/plugins/, "Commands and environment"; verified in
  `src/app/api/plugins/runtime.rs` `start_plugin_command` /
  `run_plugin_event_hooks`: `event_json = serde_json::to_string(event)` where
  `event` is an `EventEnvelope`).
- Envelope shape (`src/api/schema/events.rs:361-365`):
  `{"event": "<dot-name>", "data": { ...variant fields... }}`
- Hooks run asynchronously; up to 32 plugin commands in flight; stdout/stderr
  capped at 64 KiB each and recorded in a 200-entry log visible via
  `herdr plugin log list --plugin <id>`
  (`runtime.rs` constants; `herdr plugin log --help` verified live).

### 3.3 Payloads that matter for renaming

From `src/api/schema/events.rs` (`EventData`, lines 422-560) and
`src/api/schema/workspaces.rs` / `worktrees.rs`:

- `workspace.created` -> `{"workspace": WorkspaceInfo}`
  - `WorkspaceInfo`: `workspace_id`, `number`, `label`, `focused`,
    `pane_count`, `tab_count`, `active_tab_id`, `agent_status`,
    `tokens` (optional map), `worktree` (optional `WorkspaceWorktreeInfo`:
    `repo_key`, `repo_name`, `repo_root`, `checkout_path`,
    `is_linked_worktree`).
  - Note: no `cwd` field on the workspace itself, and no branch here.
- `worktree.created` -> `{"workspace": WorkspaceInfo, "worktree": WorktreeInfo}`
  (`worktree.opened` adds `already_open: bool`)
  - `WorktreeInfo`: `path`, `branch` (optional), `is_bare`, `is_detached`,
    `is_prunable`, `is_linked_worktree`, `open_workspace_id`, `label`.
  - **This is the best rename trigger for worktree workspaces**: one event
    carrying workspace id, checkout path, and git branch together.
- `pane.agent_detected` -> `{"pane_id", "workspace_id", "agent": Option<String>,
  "released": bool, "final_status": Option<AgentStatus>}`; the earliest
  signal of *which agent kind* started in a workspace.
- `pane.agent_status_changed` adds `title`, `display_agent`,
  `state_labels`.
- `workspace.updated` -> `{"workspace": WorkspaceInfo}`; fires often; avoid
  renaming on it (see section 5 loop discussion).

`HERDR_PLUGIN_CONTEXT_JSON` for these events is built per-event
(`src/app/api/plugins/context.rs` `plugin_context_for_event`): for
`workspace.created` / `worktree.created` / `worktree.opened` it carries the
full workspace context; `workspace_id`, `workspace_label`, `workspace_cwd`
(from the worktree label/path when worktree-backed), `worktree` object,
`tab_id`, `tab_label`, focused-pane fields, `focused_pane_agent`,
`invocation_source`, `correlation_id`
(`PluginInvocationContext`, `src/api/schema/plugins.rs:364-395`).

---

## 4. Workspace rename CLI surface (verified live)

```
herdr workspace rename <WORKSPACE_ID> <LABEL>...
```

(`herdr workspace rename --help`; multiple label args are joined by the CLI.)
Socket equivalent: `workspace.rename`
(https://herdr.dev/docs/socket-api/, request table). `workspace` subcommands:
`list`, `create`, `get`, `focus`, `rename`, `report-metadata`, `close`.

Data queryable at rename time (all outputs are JSON envelopes of the form
`{"id":"cli:<cmd>","result":{...},"type":"..."}` even without `--json`;
verified live on this session):

- `herdr workspace list` -> `result.workspaces[]`: `workspace_id`, `number`,
  `label`, `focused`, `pane_count`, `tab_count`, `active_tab_id`,
  `agent_status` (no cwd, no agent kind, no branch).
- `herdr workspace get <workspace_id>` -> same `WorkspaceInfo` shape.
- `herdr agent list` -> `result.agents[]`: `agent` (kind, e.g. `"pi"`),
  `workspace_id`, `tab_id`, `pane_id`, `cwd`, `foreground_cwd`,
  `agent_status`, `terminal_title`, `agent_session` (kind/value/source).
  This is how you map a workspace to its agent kind and cwd.
- `herdr worktree list` -> `result.source` (`repo_key`, `repo_name`,
  `repo_root`, `source_checkout_path`) + `result.worktrees[]`: `path`,
  `branch`, `is_linked_worktree`, `open_workspace_id`, `label`. Options:
  `--workspace <ID>`, `--cwd <PATH>`, `--trust-repository`; so
  `herdr worktree list --workspace <id>` resolves the worktree (and branch)
  for a workspace-backed checkout.
- `herdr workspace create --label <TEXT>` and
  `herdr worktree create --label <TEXT>` exist (verified help), i.e. an
  *explicit* label can be passed at creation time by scripts; relevant as an
  alternative for your own scripts, but not for TUI/sidebar-created
  workspaces, which is what the plugin covers.

Label constraints: presentation text is trimmed and capped (80 chars per
field per the normalization rules in the socket API docs; treat 80 chars as
the safe label budget).

---

## 5. Template/config design recommendation

### 5.1 Config location and key

Follow the reference plugin pattern (verified:
`smarzban/herdr-file-viewer/docs/configuration.md` and
`config.example.toml`): herdr gives each plugin its own config directory
(`HERDR_PLUGIN_CONFIG_DIR`, printable via `herdr plugin config-dir <id>`);
the plugin owns the file format and reads `<dir>/config.toml` itself. herdr
seeds the directory but does not validate or sync its contents
(https://herdr.dev/docs/plugins/, "Commands and environment"). Ship a
`config.example.toml` in the repo; users copy it into the config dir and
rename it to `config.toml`. herdr own `config.toml` is not extensible by
plugins (`herdr config --help` has only `check` / `reset-keys`; the config
reference has no plugin-declared keys).

Recommended config file (`$HERDR_PLUGIN_CONFIG_DIR/config.toml`):

```toml
# Template applied when a workspace is created (or a worktree is opened).
# Unmatched {vars} resolve to empty string; missing data falls back per variable.
template = "{agent-kind}/{branch}"

# Fallback when no branch is known (non-git cwd):
template-no-git = "{cwd-basename}"

# Only rename when the workspace label was never customized
# (i.e. still equals the label herdr assigned at creation): true
only-rename-unmodified = true

# Also re-apply when an agent is detected in an unnamed workspace: true
rename-on-agent-detect = true
```

### 5.2 Template variables actually available

| Variable | Source (verified) |
|---|---|
| `{workspace-id}` | event JSON `data.workspace.workspace_id`; also `HERDR_WORKSPACE_ID` |
| `{workspace-number}` | `data.workspace.number` |
| `{current-label}` | `data.workspace.label` / `HERDR_PLUGIN_CONTEXT_JSON.workspace_label` |
| `{cwd-basename}` | `HERDR_PLUGIN_CONTEXT_JSON.workspace_cwd` (basename); populated for worktree-backed workspaces from the worktree path; otherwise fall back to `herdr agent list` (`cwd`/`foreground_cwd` per `workspace_id`) |
| `{repo-name}` | `HERDR_PLUGIN_CONTEXT_JSON.worktree.repo_name` (context.rs sets `worktree` for worktree events; also present on `WorkspaceInfo.worktree`) |
| `{branch}` | event JSON `data.worktree.branch` on `worktree.created` / `worktree.opened`; otherwise `herdr worktree list --workspace <id>` -> `worktrees[].branch`; otherwise `git -C <workspace_cwd> rev-parse --abbrev-ref HEAD` |
| `{worktree-basename}` | basename of `worktree.checkout_path` / `data.worktree.path` (matches herdr `<repo>/<branch-slug>` checkout layout, docs/configuration.mdx "Worktrees") |
| `{agent-kind}` | `pane.agent_detected` event `data.agent`; or `HERDR_PLUGIN_CONTEXT_JSON.focused_pane_agent`; or `herdr agent list` -> `agents[].agent` filtered by `workspace_id` |
| `{agent-name}` | `herdr agent list` has no display-name field; socket `agent.rename` names agents but the list output shows `terminal_title` / `display_agent` only on `pane.agent_status_changed` events. Treat as best-effort: use `pane.agent_status_changed` payload `title`/`display_agent` if present |

Practical ordering: rename on `worktree.created` / `worktree.opened` first
(branch + repo available immediately), then on `workspace.created` (no branch;
use `{cwd-basename}` or async git lookup), then optionally on
`pane.agent_detected` to fill `{agent-kind}` for still-unnamed workspaces.

### 5.3 Loop/churn safety

- Do **not** hook `workspace.updated`; it fires for many lifecycle changes
  and renaming from it risks feedback churn. `workspace.renamed` **is**
  hookable; a plugin that renamed inside its own `workspace.renamed` hook
  would recurse. Stick to creation-time events and re-check the current label
  (`workspace.label` in the event payload) before calling rename.
- Idempotency guard: skip when `only-rename-unmodified` and the current label
  no longer equals the label observed at creation (store it in
  `HERDR_PLUGIN_STATE_DIR`), so user renames are respected.

---

## 6. Skeleton manifest + hook pseudocode

### `herdr-plugin.toml` (grounded in verified 0.9.1 syntax)

```toml
id = "example.workspace-auto-rename"
name = "Workspace Auto Rename"
version = "0.1.0"
min_herdr_version = "0.9.1"
description = "Rename workspaces from a template when they are created"
platforms = ["linux", "macos", "windows"]

# Optional: rename existing unnamed workspaces when the server starts.
# Startup hooks run once per enabled plugin after session restore, with
# HERDR_PLUGIN_EVENT=startup (https://herdr.dev/docs/plugins/, "Startup hooks").
[[startup]]
command = ["bash", "hooks/rename-existing.sh"]

# Worktree-backed workspaces: branch + repo known at creation.
[[events]]
on = "worktree.created"
command = ["bash", "hooks/on-event.sh"]

[[events]]
on = "worktree.opened"
command = ["bash", "hooks/on-event.sh"]

# Plain workspaces: rename from cwd; agent kind filled in later if desired.
[[events]]
on = "workspace.created"
command = ["bash", "hooks/on-event.sh"]

# Optional: fill {agent-kind} for workspaces still carrying their birth label.
[[events]]
on = "pane.agent_detected"
command = ["bash", "hooks/on-event.sh"]

[[actions]]
id = "apply-now"
title = "Re-apply rename template"
contexts = ["workspace"]
command = ["bash", "hooks/on-event.sh"]   # context JSON supplies the workspace
```

### `hooks/on-event.sh` pseudocode (bash + jq)

```bash
#!/usr/bin/env bash
set -euo pipefail
HERDR="${HERDR_BIN_PATH:-herdr}"
CFG="$HERDR_PLUGIN_CONFIG_DIR/config.toml"     # user-editable template

ws_id="$(printf '%s' "$HERDR_PLUGIN_CONTEXT_JSON" | jq -r '.workspace_id // empty')"
[ -n "$ws_id" ] || exit 0

# Pull current snapshot (label + worktree info) authoritatively:
snap="$("$HERDR" workspace get "$ws_id")"
label_now="$(jq -r '.result.label // empty' <<<"$snap")"

template="$(toml_get "$CFG" template || echo '{cwd-basename}')"

# Gather variables, preferring event JSON, then CLI:
branch="$(jq -r '.data.worktree.branch // empty' <<<"$HERDR_PLUGIN_EVENT_JSON")"
repo="$(  jq -r '.worktree.repo_name // empty' <<<"$HERDR_PLUGIN_CONTEXT_JSON")"
cwd="$(   jq -r '.workspace_cwd // empty' <<<"$HERDR_PLUGIN_CONTEXT_JSON")"
agent="$( jq -r '.data.agent // empty' <<<"$HERDR_PLUGIN_EVENT_JSON")"
[ -n "$branch" ] || branch="$("$HERDR" worktree list --workspace "$ws_id" 2>/dev/null \
                        | jq -r '.result.worktrees[0].branch // empty')"
[ -n "$agent"  ] || agent="$("$HERDR" agent list | jq -r --arg w "$ws_id" \
                        '.result.agents[]|select(.workspace_id==$w)|.agent' | head -n1)"

new_label="$(render_template "$template")"   # substitute {branch}, {repo-name},
                                             # {cwd-basename}, {agent-kind}, ...

# Guards: never rename inside workspace.renamed; skip if unchanged; skip if the
# user renamed it after creation (state dir records the birth label).
[ "$new_label" = "$label_now" ] && exit 0
state="$HERDR_PLUGIN_STATE_DIR/birth-label-$ws_id"
if [ -f "$state" ] && [ "$label_now" != "$(cat "$state")" ]; then exit 0; fi
echo -n "$label_now" > "$state" 2>/dev/null || true

"$HERDR" workspace rename "$ws_id" "$new_label"
```

Notes on the skeleton:
- Commands are argv arrays, no shell: hooks that need shell semantics declare
  `["bash", "hooks/..."]` themselves (docs, "Manifest").
- The hook cwd is the plugin root; reference scripts by absolute path via
  `HERDR_PLUGIN_ROOT` if you change directories.
- For debugging, `herdr plugin log list --plugin <id>` shows exit code and
  capped stdout/stderr per hook invocation (docs; `herdr plugin log --help`).
- For distribution, follow the reference plugin packaging
  (`herdr-plugin.toml:40-49`): a per-platform `[[build]]` that downloads a
  prebuilt binary (SHA-256 verified) and falls back to `cargo build`; tag
  GitHub releases; add topic `herdr-plugin` for the marketplace
  (https://herdr.dev/docs/plugins/, "Marketplace"). For a pure bash/jq plugin
  no `[[build]]` is needed at all.

### Windows quirks (from the reference plugin header,
`herdr-plugin.toml:8-19`, verified against herdr 0.7.1 by its author)

- herdr can fail to spawn **relative** pane commands on Windows
  (`CreateProcessW` resolves against herdr own directory); launchers there
  resolve scripts via `plugin list --json` -> `plugin_root` (strip `\\?\`
  verbatim prefix) and spawn by absolute path.
- `plugin list --json` field access pattern for that workaround is shown in
  the manifest embedded PowerShell (lines 82-86).
- No aarch64 Windows target in v1 (x86_64-pc-windows-msvc only).
- PATHEXT shims (`npm.cmd` etc.) resolve for build/action/event commands on
  Windows, but pane commands use the normal Windows launcher
  (https://herdr.dev/docs/plugins/, "Panes" last paragraph). For this plugin,
  PowerShell entrypoints or a compiled binary sidestep all of this.

---

## 7. Native alternative check (prominent finding)

**No native workspace auto-naming template exists in 0.9.1.** Verified:

- Full config reference
  (`herdrdev/herdr@v0.9.1 docs/next/website/src/data/config-reference.json`,
  all 1522 lines scanned for workspace/worktree/template/label keys): the only
  naming-adjacent keys are `keys.rename_workspace` (keybinding),
  `ui.prompt_new_workspace_name` (boolean: "Ask for a workspace name before
  interactive TUI creation", default false), and `worktrees.directory`
  (checkout root; herdr names checkouts `<dir>/<repo>/<branch-slug>` per
  docs/configuration.mdx "Worktrees" -- but the *workspace label* is not
  templated).
- No template/naming keys in the preview-channel docs
  (`https://herdr.dev/llms-preview.txt` searched for template/naming: no hits).
- `herdr workspace create` / `herdr worktree create` accept an explicit
  `--label` (verified help), but that only helps scripts that create
  workspaces themselves; TUI/sidebar-created workspaces get herdr default
  label, which is exactly the gap a plugin fills.

---

## 8. Open questions / unverified areas

1. **Server-restore behavior**: whether `workspace.created` /
   `worktree.opened` hooks fire for workspaces restored at server boot
   (i.e. whether the events replay during session restore). The `[[startup]]`
   hook is the documented way to act after restore; renaming existing
   workspaces at startup needs `herdr workspace list` + `worktree list`.
   Unverified (would require restarting the live server, which is out of
   scope for read-only research).
2. **Default birth label**: what exact label herdr assigns to a fresh
   TUI-created workspace or worktree workspace (needed for the
   `only-rename-unmodified` guard). `WorkspaceInfo.label` is in the event
   payload, so the plugin can capture it at hook time regardless; confirming
   the default string would require creating a workspace (deliberately not
   done).
3. **Rename-length clamp on the CLI path**: the 80-char presentation cap is
   documented for socket/metadata normalization
   (https://herdr.dev/docs/socket-api/); whether `herdr workspace rename`
   truncates or errors beyond 80 chars was not verified live.
4. **`workspace.updated` on rename**: whether a rename also emits
   `workspace.updated` (relevant only if someone hooks it; recommended design
   avoids it). Source review suggests `renamed` and `updated` are separate
   variants, but the emission sites were not audited.
5. **Event ordering**: whether `workspace.created` and `worktree.created`
   both fire for a single sidebar "New worktree" action (the socket API docs
   say `worktree.created` "includes the opened `workspace` and created
   `worktree`", implying both fire). An idempotency guard (label-unchanged
   check) makes double-firing harmless.
6. **Agent rename field**: `herdr agent rename <target> <name>` exists
   (https://herdr.dev/docs/cli-reference/), but `herdr agent list` output
   showed no `display_name` field live; agent display naming surface may
   differ from what `{agent-name}` would want.

## 9. Source index

Primary (installed binary, read-only commands):
`herdr --help`, `herdr plugin --help` + subcommand help, `herdr workspace`
/ `worktree` / `config` / `agent` help, live `workspace list`, `agent list`,
`worktree list`, `plugin list --json`, `plugin config-dir herdr-file-viewer`.

Official docs (herdr.dev, stable = 0.9.1):
- https://herdr.dev/docs/plugins/ (raw:
  `herdrdev/herdr@v0.9.1 .../docs/plugins.mdx`)
- https://herdr.dev/docs/socket-api/ (`.../socket-api.mdx`)
- https://herdr.dev/docs/cli-reference/ (`.../cli-reference.mdx`)
- https://herdr.dev/docs/configuration.mdx ; config reference JSON
- https://herdr.dev/llms.txt , https://herdr.dev/llms-preview.txt

Source (herdrdev/herdr, tag v0.9.1, fetched raw):
- `src/api/schema/events.rs` (PLUGIN_HOOK_EVENT_KINDS, EventData,
  plugin_hook_event_names)
- `src/api/schema/plugins.rs` (manifest structs,
  PluginInvocationContext, warnings)
- `src/api/schema/workspaces.rs`, `src/api/schema/worktrees.rs`
  (WorkspaceInfo, WorkspaceWorktreeInfo, WorktreeInfo)
- `src/app/api/plugins/manifest.rs`, `runtime.rs`, `context.rs`
- `src/plugin_paths.rs`

Local reference plugin: `/home/lucas/source/smarzban/herdr-file-viewer`
(`herdr-plugin.toml`, `docs/configuration.md`, `config.example.toml`,
`AGENTS.md`).
