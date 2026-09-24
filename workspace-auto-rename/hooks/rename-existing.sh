#!/usr/bin/env bash
# rename-existing.sh: [[startup]] hook for workspace-auto-rename.
#
# Re-applies the template to existing workspaces after a session restore.
# Existing workspaces have no recorded birth label, so each one is processed
# with kind "adopt": they are renamed only when the adopt-existing config key
# is true (the default), and their observed labels are recorded as birth
# labels either way. Opt-in like everything else: inert without a configured
# template.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hooks/lib.sh
source "$HERE/lib.sh"

require_jq
load_config

if [ -z "$TEMPLATE" ]; then
    exit 0
fi

ws_json="$(run_herdr workspace list 2>/dev/null || true)"
ag_json="$(run_herdr agent list 2>/dev/null || true)"

# TSV rows: workspace_id, label, number.
while IFS=$'\t' read -r ws_id label number _extra; do
    if [ -z "$ws_id" ] || [ -z "$label" ]; then
        continue
    fi

    wt_json="$(run_herdr worktree list --workspace "$ws_id" 2>/dev/null || true)"

    # $w is a jq variable bound by --arg, not a shell expansion.
    # shellcheck disable=SC2016
    cwd="$(jget "$ag_json" --arg w "$ws_id" '([.result.agents // [] | .[] | select(.workspace_id == $w)][0].cwd) // empty')"

    wt_entry="$(worktree_for_ws "$wt_json" "$ws_id" "$cwd")"
    branch="$(jget "$wt_entry" '.branch // empty')"
    wt_path="$(jget "$wt_entry" '.path // empty')"
    if [ -z "$cwd" ]; then
        cwd="$wt_path"
    fi

    # Repo name: herdr's worktree source info first (authoritative even for
    # linked worktrees whose checkout directory is named after the branch),
    # then the main git repository root for the pane cwd.
    repo="$(jget "$wt_json" '.result.source.repo_name // empty')"
    if [ -z "$repo" ]; then
        repo="$(git_repo_name "$cwd")"
    fi

    # shellcheck disable=SC2016
    agent="$(jget "$ag_json" --arg w "$ws_id" '([.result.agents // [] | .[] | select(.workspace_id == $w)][0].agent) // empty')"

    apply_rename "adopt" "$ws_id" "$label" "$number" "$branch" "$repo" "$cwd" "$wt_path" "$agent" || true
done < <(printf '%s' "$ws_json" | jq -r '[(.result.workspaces // [])[] | [.workspace_id, (.label // ""), ((.number // "") | tostring)]] | .[] | @tsv' 2>/dev/null || true)

exit 0
