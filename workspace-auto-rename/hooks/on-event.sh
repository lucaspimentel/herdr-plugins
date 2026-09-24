#!/usr/bin/env bash
# on-event.sh: herdr event and action hook for workspace-auto-rename.
#
# Reads the event envelope and invocation context from the environment,
# gathers template variables with the precedence event JSON > context JSON >
# herdr CLI > git, and renames the workspace when the configured template and
# the birth-label guard allow it.
#
# The plugin is opt-in: without a configured template this script exits 0
# without touching anything.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hooks/lib.sh
source "$HERE/lib.sh"

require_jq
load_config

# No template configured: the plugin is inert by design.
if [ -z "$TEMPLATE" ]; then
    exit 0
fi

event="${HERDR_PLUGIN_EVENT:-action}"
event_json="${HERDR_PLUGIN_EVENT_JSON:-}"
context_json="${HERDR_PLUGIN_CONTEXT_JSON:-}"

if [ "$event" = "pane.agent_detected" ] && [ "$RENAME_ON_AGENT_DETECT" != "true" ]; then
    exit 0
fi

# Workspace id: context, then event payload, then the caller's own workspace.
ws_id="$(jget "$context_json" '.workspace_id // empty')"
if [ -z "$ws_id" ]; then
    ws_id="$(jget "$event_json" '.data.workspace.workspace_id // empty')"
fi
if [ -z "$ws_id" ]; then
    ws_id="${HERDR_WORKSPACE_ID:-}"
fi
if [ -z "$ws_id" ]; then
    exit 0
fi

# Authoritative snapshot from the CLI, used as a fallback for label, number,
# and worktree data.
ws_json="$(run_herdr workspace get "$ws_id" 2>/dev/null || true)"

current="$(jget "$context_json" '.workspace_label // empty')"
if [ -z "$current" ]; then
    current="$(jget "$event_json" '.data.workspace.label // empty')"
fi
if [ -z "$current" ]; then
    current="$(jget "$ws_json" '.result.label // empty')"
fi
if [ -z "$current" ]; then
    exit 0
fi

number="$(jget "$event_json" '.data.workspace.number // empty')"
if [ -z "$number" ]; then
    number="$(jget "$ws_json" '.result.number // empty')"
fi

# Branch: event payload, then context, then the worktree CLI, then git.
branch="$(jget "$event_json" '.data.worktree.branch // empty')"
if [ -z "$branch" ]; then
    branch="$(jget "$context_json" '.worktree.branch // empty')"
fi

wt_path="$(jget "$event_json" '.data.worktree.path // empty')"
if [ -z "$wt_path" ]; then
    wt_path="$(jget "$context_json" '.worktree.checkout_path // empty')"
fi
if [ -z "$wt_path" ]; then
    wt_path="$(jget "$event_json" '.data.workspace.worktree.checkout_path // empty')"
fi

# cwd: context, then worktree checkout path, then the agent list.
cwd="$(jget "$context_json" '.workspace_cwd // empty')"
if [ -z "$cwd" ]; then
    cwd="$wt_path"
fi
if [ -z "$cwd" ]; then
    ag_json="$(run_herdr agent list 2>/dev/null || true)"
    # $w is a jq variable bound by --arg, not a shell expansion.
    # shellcheck disable=SC2016
    cwd="$(jget "$ag_json" --arg w "$ws_id" '([.result.agents // [] | .[] | select(.workspace_id == $w)][0].cwd) // empty')"
fi

# Repo name: context, then event payload, then the worktree CLI, then git.
# The worktree CLI is authoritative because linked worktree checkout
# directories are often named after the branch, not the repo.
repo="$(jget "$context_json" '.worktree.repo_name // empty')"
if [ -z "$repo" ]; then
    repo="$(jget "$event_json" '.data.workspace.worktree.repo_name // empty')"
fi

if [ -z "$branch" ] || [ -z "$repo" ]; then
    wt_json="$(run_herdr worktree list --workspace "$ws_id" 2>/dev/null || true)"
    if [ -z "$branch" ]; then
        wt_entry="$(worktree_for_ws "$wt_json" "$ws_id" "$cwd")"
        branch="$(jget "$wt_entry" '.branch // empty')"
        if [ -z "$wt_path" ]; then
            wt_path="$(jget "$wt_entry" '.path // empty')"
        fi
    fi
    if [ -z "$repo" ]; then
        repo="$(jget "$wt_json" '.result.source.repo_name // empty')"
    fi
fi

if [ -z "$repo" ]; then
    repo="$(git_repo_name "$cwd")"
fi

# Agent kind: event payload, then context, then the agent list.
agent="$(jget "$event_json" '.data.agent // empty')"
if [ -z "$agent" ]; then
    agent="$(jget "$context_json" '.focused_pane_agent // empty')"
fi
if [ -z "$agent" ]; then
    ag_json="$(run_herdr agent list 2>/dev/null || true)"
    # $w is a jq variable bound by --arg, not a shell expansion.
    # shellcheck disable=SC2016
    agent="$(jget "$ag_json" --arg w "$ws_id" '([.result.agents // [] | .[] | select(.workspace_id == $w)][0].agent) // empty')"
fi

case "$event" in
    workspace.created | worktree.created | worktree.opened) kind="creation" ;;
    *) kind="adopt" ;;
esac

apply_rename "$kind" "$ws_id" "$current" "$number" "$branch" "$repo" "$cwd" "$wt_path" "$agent"
