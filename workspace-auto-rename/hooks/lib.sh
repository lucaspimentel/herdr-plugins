#!/usr/bin/env bash
# lib.sh: shared logic for workspace-auto-rename hooks.
#
# Sourced by hooks/on-event.sh, hooks/rename-existing.sh, and
# tests/run-tests.sh. All herdr CLI access goes through run_herdr() so tests
# can stub it by pointing HERDR_BIN_PATH at a fake script.

set -euo pipefail

# Presentation labels are capped at 80 chars by herdr (socket API
# normalization rules); treat 80 as the safe budget.
LABEL_MAX=80

# Template variable values, consumed by render_template.
V_WORKSPACE_ID=""
V_WORKSPACE_NUMBER=""
V_CURRENT_LABEL=""
V_CWD_BASENAME=""
V_REPO_NAME=""
V_BRANCH=""
V_WORKTREE_BASENAME=""
V_AGENT_KIND=""
V_AGENT_NAME=""
V_PR=""

# Newline-separated "repo<TAB>alias" pairs, populated by load_repo_aliases.
# A plain string (not an associative array) keeps macOS bash 3.2 compatible.
REPO_ALIASES=""

# Config values, populated by load_config.
TEMPLATE=""
TEMPLATE_NO_GIT='{cwd-basename}'
ONLY_RENAME_UNMODIFIED="true"
RENAME_ON_AGENT_DETECT="true"
RENAME_ON_CWD_CHANGE="true"
ADOPT_EXISTING="true"
# {pr} cache lifetimes in seconds: hits (a resolved PR number) default to a
# day, misses ("none") to an hour, so a PR opened after a miss is picked up
# on a later render. 0 disables expiry.
PR_HIT_TTL="86400"
PR_MISS_TTL="3600"

# Extra labels treated as unmodified by decide_rename, one per line. Set by
# on-event.sh for cwd-change events so herdr's own auto-naming from a
# previous cwd is not mistaken for a manual rename.
EXTRA_OK_LABELS=""

die() {
    printf 'workspace-auto-rename: %s\n' "$*" >&2
    exit 1
}

require_jq() {
    command -v jq >/dev/null 2>&1 || die "jq is required but not installed"
}

# Run the herdr CLI. Tests stub this via HERDR_BIN_PATH.
run_herdr() {
    local bin="${HERDR_BIN_PATH:-herdr}"
    "$bin" "$@"
}

# Extract a value from a JSON string. The filter must end with "// empty" so
# missing keys render as empty output rather than the string "null". Any
# additional arguments are passed to jq verbatim (e.g. --arg), before the
# filter. Any jq error yields empty output.
jget() {
    local json="$1"
    shift
    printf '%s' "$json" | jq -r "$@" 2>/dev/null || true
}

# Strip leading and trailing whitespace.
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Print the value of a simple `key = "value"` entry from a TOML file. Only
# flat string keys are supported, which is all this plugin's config uses.
# Prints nothing when the file or key is absent.
config_get() {
    local file="$1" key="$2" line
    [ -f "$file" ] || return 0
    line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" | tail -n 1 || true)"
    [ -n "$line" ] || return 0
    line="${line#*=}"
    line="$(trim "$line")"
    if [[ "$line" == \"*\" && ${#line} -ge 2 ]]; then
        line="${line#\"}"
        line="${line%\"}"
    fi
    printf '%s' "$line"
}

# Print the final path component; empty input yields empty output.
basename_of() {
    local p="$1"
    [ -n "$p" ] || return 0
    p="${p%/}"
    printf '%s' "${p##*/}"
}

# Derive a repository display name for a directory. Prefers the main
# repository root over the checkout path: linked worktree checkouts are
# often named after the branch (for example "repo.branch-slug"), so the
# checkout basename is not the repo name. Prints the name, or nothing when
# the directory is not inside a git repository.
git_repo_name() {
    local dir="$1" common main top
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        return 0
    fi
    common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [ -n "$common" ]; then
        main="$common"
        case "$main" in
            */.git/worktrees/*) main="${main%/.git/worktrees/*}" ;;
            */.git)             main="${main%/.git}" ;;
        esac
        printf '%s' "$(basename_of "$main")"
        return 0
    fi
    top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$top" ]; then
        printf '%s' "$(basename_of "$top")"
    fi
}

# Load config.toml into globals. The plugin is opt-in: TEMPLATE stays empty
# unless the user configured one, and every entry point checks for it before
# doing anything.
load_config() {
    local cfg="${HERDR_PLUGIN_CONFIG_DIR:-}/config.toml"
    TEMPLATE="$(config_get "$cfg" template)"
    load_repo_aliases "$cfg"
    TEMPLATE_NO_GIT="$(config_get "$cfg" template-no-git)"
    if [ -z "$TEMPLATE_NO_GIT" ]; then
        TEMPLATE_NO_GIT='{cwd-basename}'
    fi
    ONLY_RENAME_UNMODIFIED="$(config_get "$cfg" only-rename-unmodified)"
    if [ -z "$ONLY_RENAME_UNMODIFIED" ]; then
        ONLY_RENAME_UNMODIFIED="true"
    fi
    RENAME_ON_AGENT_DETECT="$(config_get "$cfg" rename-on-agent-detect)"
    if [ -z "$RENAME_ON_AGENT_DETECT" ]; then
        RENAME_ON_AGENT_DETECT="true"
    fi
    RENAME_ON_CWD_CHANGE="$(config_get "$cfg" rename-on-cwd-change)"
    if [ -z "$RENAME_ON_CWD_CHANGE" ]; then
        RENAME_ON_CWD_CHANGE="true"
    fi
    ADOPT_EXISTING="$(config_get "$cfg" adopt-existing)"
    if [ -z "$ADOPT_EXISTING" ]; then
        ADOPT_EXISTING="true"
    fi
    PR_HIT_TTL="$(config_get "$cfg" pr-hit-ttl-seconds)"
    if ! [[ "$PR_HIT_TTL" =~ ^[0-9]+$ ]]; then
        PR_HIT_TTL="86400"
    fi
    PR_MISS_TTL="$(config_get "$cfg" pr-miss-ttl-seconds)"
    if ! [[ "$PR_MISS_TTL" =~ ^[0-9]+$ ]]; then
        PR_MISS_TTL="3600"
    fi
}

# Substitute {var} placeholders in a template. Unknown placeholders render as
# empty strings.
render_template() {
    local template="$1"
    local out="$template"
    local name value
    for name in workspace-id workspace-number current-label cwd-basename \
                repo-name branch worktree-basename agent-kind agent-name pr; do
        case "$name" in
            workspace-id)      value="$V_WORKSPACE_ID" ;;
            workspace-number)  value="$V_WORKSPACE_NUMBER" ;;
            current-label)     value="$V_CURRENT_LABEL" ;;
            cwd-basename)      value="$V_CWD_BASENAME" ;;
            repo-name)         value="$V_REPO_NAME" ;;
            branch)            value="$V_BRANCH" ;;
            worktree-basename) value="$V_WORKTREE_BASENAME" ;;
            agent-kind)        value="$V_AGENT_KIND" ;;
            agent-name)        value="$V_AGENT_NAME" ;;
            pr)                value="$V_PR" ;;
        esac
        out="${out//"{$name}"/$value}"
    done
    # Unknown placeholders render as empty strings.
    out="$(printf '%s' "$out" | sed -E 's/\{[^}]*\}//g')"
    printf '%s' "$out"
}

# Extract the worktree entry for a workspace from a `herdr worktree list`
# response. Preference order: the worktree whose checkout path matches the
# workspace cwd (the pane's current location; open_workspace_id goes stale
# after a cd), then the worktree opened in that workspace, then the first
# entry, but only when the repo has exactly one worktree (guessing a branch
# in a multi-worktree repo risks a wrong PR number). Prints a JSON object or
# nothing.
worktree_for_ws() {
    local json="$1" ws_id="$2" cwd="$3"
    # $w and $c are jq variables bound by --arg, not shell expansions.
    # shellcheck disable=SC2016
    printf '%s' "$json" | jq -c --arg w "$ws_id" --arg c "$cwd" \
        '([.result.worktrees // [] | .[] | select($c != "" and .path == $c)][0]
          // ([.result.worktrees // [] | .[] | select(.open_workspace_id == $w)][0])
          // (if ((.result.worktrees // []) | length) == 1 then (.result.worktrees // [])[0] else empty end)
          // empty)' 2>/dev/null || true
}

# Parse the [repo-alias] table from config.toml into REPO_ALIASES. Only keys
# inside that section are collected; any other section ends the collection.
# Values follow the same simple "key = \"value\"" shape as config_get.
load_repo_aliases() {
    local file="$1" line section="" key value
    REPO_ALIASES=""
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(trim "$line")"
        case "$line" in
            ''|'#'*) continue ;;
            '['*)
                section="${line#\[}"
                section="${section%\]}"
                section="$(trim "$section")"
                continue
                ;;
        esac
        if [ "$section" = "repo-alias" ]; then
            key="${line%%=*}"
            value="${line#*=}"
            key="$(trim "$key")"
            value="$(trim "$value")"
            if [[ "$value" == \"*\" && ${#value} -ge 2 ]]; then
                value="${value#\"}"
                value="${value%\"}"
            fi
            if [ -n "$key" ] && [ -n "$value" ]; then
                REPO_ALIASES+="${key}"$'\t'"${value}"$'\n'
            fi
        fi
    done < "$file"
}

# Print the alias for a repo name, or the name itself when unmapped. Empty
# input yields empty output.
repo_alias() {
    local name="$1" key value
    if [ -z "$name" ]; then
        return 0
    fi
    while IFS=$'\t' read -r key value || [ -n "$key" ]; do
        if [ "$key" = "$name" ]; then
            printf '%s' "$value"
            return 0
        fi
    done <<< "$REPO_ALIASES"
    printf '%s' "$name"
}

# Path of the PR cache file for a "repo/branch" key, or a failed status when
# there is no state dir. Unsafe filename characters are replaced with "_"
# and the result is truncated to keep it a plain filename.
pr_cache_file() {
    local state_dir="${HERDR_PLUGIN_STATE_DIR:-}"
    if [ -z "$state_dir" ]; then
        return 1
    fi
    local safe
    safe="$(printf '%s' "$1" | sed -E 's/[^A-Za-z0-9._-]/_/g')"
    printf '%s/pr-cache/%s' "$state_dir" "${safe:0:120}"
}

# Read a cached {pr} lookup result and enforce its TTL. Prints the cached
# value (a number for a hit, "none" for a fresh miss, so the caller can tell
# it apart from having no cache entry) and nothing when the entry is
# missing, malformed, or expired. Cache entries store "<value>|<epoch>".
# A TTL of 0 means never expire. Entries written before TTL support (no
# timestamp) count as expired, so stale pre-TTL caches are re-resolved once
# and rewritten in the new format.
pr_cache_read() {
    local repo="$1" branch="$2" file line num ts ttl age now
    file="$(pr_cache_file "$repo/$branch")" || return 0
    [ -f "$file" ] || return 0
    line="$(<"$file")"
    case "$line" in
        *'|'[0-9]*)
            num="${line%|*}"
            ts="${line##*|}"
            ;;
        *)
            # Legacy format without a timestamp: treat as expired.
            return 0
            ;;
    esac
    if [ "$num" = "none" ]; then
        if [ "$PR_MISS_TTL" = "0" ]; then
            printf 'none'
            return 0
        fi
        ttl="$PR_MISS_TTL"
    elif [[ "$num" =~ ^[0-9]+$ ]]; then
        if [ "$PR_HIT_TTL" = "0" ]; then
            printf '%s' "$num"
            return 0
        fi
        ttl="$PR_HIT_TTL"
    else
        # Malformed value: re-resolve.
        return 0
    fi
    now="$(date +%s)"
    age=$((now - ts))
    if [ "$age" -lt "$ttl" ]; then
        printf '%s' "$num"
    fi
}

# Extract a PR number encoded in a branch name. Recognized shapes:
#   pr-123, pr/123, pr-123-short-description, pr123, 123, 123-short-description
# Prints the number and returns 0 on a match; returns 1 otherwise.
pr_from_branch_pattern() {
    local branch="$1" re
    re='^pr[-/]([0-9]+)([-_.].+)?$'
    [[ "$branch" =~ $re ]] && { printf '%s' "${BASH_REMATCH[1]}"; return 0; }
    re='^pr([0-9]+)$'
    [[ "$branch" =~ $re ]] && { printf '%s' "${BASH_REMATCH[1]}"; return 0; }
    re='^([0-9]+)([-_/].+)?$'
    [[ "$branch" =~ $re ]] && { printf '%s' "${BASH_REMATCH[1]}"; return 0; }
    return 1
}

# Look up the PR number with the GitHub CLI, run inside the worktree
# directory so gh can resolve the repository from the git remote. Prints the
# number or nothing; network problems and a missing gh binary are treated as
# a miss, never as an error. GH_BIN overrides the binary (used by tests).
pr_from_gh() {
    local branch="$1" dir="$2" gh out
    gh="${GH_BIN:-gh}"
    command -v "$gh" >/dev/null 2>&1 || return 0
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        return 0
    fi
    local runner=("$gh")
    if command -v timeout >/dev/null 2>&1; then
        runner=(timeout 10 "$gh")
    fi
    out="$( (cd "$dir" && "${runner[@]}" pr list --head "$branch" --state all --json number --jq '.[0].number') 2>/dev/null || true)"
    printf '%s' "$(trim "$out")"
}

# Resolve the GitHub PR number for a branch, if one can be found. Detection
# order: cached value (subject to its TTL), branch-name pattern, gh CLI
# lookup. Prints the number or nothing. Both hits and misses are cached in
# the plugin state dir with a timestamp: hits expire after
# pr-hit-ttl-seconds, misses after pr-miss-ttl-seconds, so a PR opened after
# a miss is picked up on a later render.
resolve_pr() {
    local branch="$1" repo="$2" wt_path="$3"
    local num="" cache="" now

    [ -n "$branch" ] || return 0

    if cache="$(pr_cache_file "$repo/$branch")"; then
        num="$(pr_cache_read "$repo" "$branch")"
        if [ "$num" = "none" ]; then
            return 0
        fi
        if [ -n "$num" ]; then
            printf '%s' "$num"
            return 0
        fi
    fi

    if num="$(pr_from_branch_pattern "$branch")"; then
        num="$(trim "$num")"
    else
        num=""
    fi

    if [ -z "$num" ]; then
        num="$(pr_from_gh "$branch" "$wt_path")" || num=""
    fi

    # Only digits count as a hit.
    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
        num=""
    fi

    if [ -n "$cache" ]; then
        mkdir -p "${cache%/*}" 2>/dev/null || true
        now="$(date +%s)"
        if [ -n "$num" ]; then
            printf '%s|%s' "$num" "$now" > "$cache" 2>/dev/null || true
        else
            printf 'none|%s' "$now" > "$cache" 2>/dev/null || true
        fi
    fi

    if [ -n "$num" ]; then
        printf '%s' "$num"
    fi
    return 0
}

# Decide whether a workspace may be renamed, implementing the birth-label
# guard. Args: kind ("creation" or "adopt"), workspace id, current label,
# newly rendered label. Prints "rename" or "skip".
#
# State files in HERDR_PLUGIN_STATE_DIR:
#   birth-<ws_id>    the label herdr assigned at creation
#   applied-<ws_id>  the last label this plugin set
#
# Rules:
#   - current == rendered target: skip (idempotency; this also makes our own
#     earlier renames a no-op instead of tripping the guard)
#   - only-rename-unmodified = false: always rename
#   - birth label known: rename only when the current label equals the birth
#     label or the last applied label; anything else is a manual user rename
#   - no birth label on record: creation events are authoritative; every
#     other kind (startup, agent detection, action) renames only when
#     adopt-existing is true. Either way the observed label is recorded as
#     the birth label.
decide_rename() {
    local kind="$1" ws_id="$2" current="$3" new="$4"
    local state_dir="${HERDR_PLUGIN_STATE_DIR:-}"

    if [ -z "$state_dir" ]; then
        printf 'rename\n'
        return 0
    fi
    mkdir -p "$state_dir" 2>/dev/null || true

    local birth_file="$state_dir/birth-$ws_id"
    local applied_file="$state_dir/applied-$ws_id"
    local had_birth=0
    local birth=""
    local applied=""

    if [ -f "$birth_file" ]; then
        birth="$(<"$birth_file")"
        if [ -n "$birth" ]; then
            had_birth=1
        fi
    fi
    if [ "$had_birth" = "0" ]; then
        printf '%s' "$current" > "$birth_file"
    fi
    if [ -f "$applied_file" ]; then
        applied="$(<"$applied_file")"
    fi

    if [ "$current" = "$new" ]; then
        printf 'skip\n'
        return 0
    fi

    if [ "$ONLY_RENAME_UNMODIFIED" != "true" ]; then
        printf 'rename\n'
        return 0
    fi

    # Cwd-change events may relax the guard: herdr auto-renames workspaces
    # after a cd (label becomes the cwd basename), which is not a manual
    # rename. This check intentionally precedes the adopt-existing gate: a
    # stale pre-install name after a cd is still stale.
    if label_in_extra "$current"; then
        printf 'rename\n'
        return 0
    fi

    if [ "$had_birth" = "1" ]; then
        if [ "$current" = "$birth" ]; then
            printf 'rename\n'
            return 0
        fi
        if [ -n "$applied" ] && [ "$current" = "$applied" ]; then
            printf 'rename\n'
            return 0
        fi
        printf 'skip\n'
        return 0
    fi

    if [ "$kind" = "creation" ] || [ "$ADOPT_EXISTING" = "true" ]; then
        printf 'rename\n'
    else
        printf 'skip\n'
    fi
    return 0
}

# Record the label we just applied, so later events can distinguish our own
# renames from manual user renames.
record_applied() {
    local state_dir="${HERDR_PLUGIN_STATE_DIR:-}"
    [ -n "$state_dir" ] || return 0
    mkdir -p "$state_dir" 2>/dev/null || true
    printf '%s' "$2" > "$state_dir/applied-$1" 2>/dev/null || true
    return 0
}

# Record the cwd a workspace was last rendered from, so focus events can
# detect cwd changes.
record_cwd() {
    local state_dir="${HERDR_PLUGIN_STATE_DIR:-}"
    [ -n "$state_dir" ] || return 0
    [ -n "$2" ] || return 0
    mkdir -p "$state_dir" 2>/dev/null || true
    printf '%s' "$2" > "$state_dir/cwd-$1" 2>/dev/null || true
    return 0
}

# True when the label equals one of the extra allowed labels (one per line,
# blank lines ignored).
label_in_extra() {
    local label="$1" entry
    [ -n "$EXTRA_OK_LABELS" ] || return 1
    while IFS= read -r entry || [ -n "$entry" ]; do
        if [ -n "$entry" ] && [ "$label" = "$entry" ]; then
            return 0
        fi
    done <<< "$EXTRA_OK_LABELS"
    return 1
}

# Render the template for the supplied values and rename the workspace when
# the guard allows it. Args:
#   kind     "creation" or "adopt"
#   ws_id    workspace id
#   current  current label
#   number   workspace number (may be empty)
#   branch   git branch (may be empty)
#   repo     repository name (may be empty)
#   cwd      workspace cwd (may be empty)
#   wt_path  worktree checkout path (may be empty)
#   agent    agent kind (may be empty)
#
# Returns 0 when nothing needed doing or the rename succeeded; nonzero only
# when the rename call itself failed.
apply_rename() {
    local kind="$1" ws_id="$2" current="$3" number="$4" branch="$5" \
          repo="$6" cwd="$7" wt_path="$8" agent="$9"

    V_WORKSPACE_ID="$ws_id"
    V_WORKSPACE_NUMBER="$number"
    V_CURRENT_LABEL="$current"
    V_CWD_BASENAME="$(basename_of "$cwd")"
    V_REPO_NAME="$(repo_alias "$repo")"
    V_BRANCH="$branch"
    V_WORKTREE_BASENAME="$(basename_of "$wt_path")"
    V_AGENT_KIND="$agent"
    V_AGENT_NAME=""

    local template="$TEMPLATE_NO_GIT"
    if [ -n "$branch" ]; then
        template="$TEMPLATE"
    fi

    # PR lookup runs only when the chosen template actually uses {pr}, so
    # users without that placeholder never pay for a network call.
    V_PR=""
    if [[ "$template" == *'{pr}'* ]] && [ -n "$branch" ]; then
        local pr
        pr="$(resolve_pr "$branch" "$repo" "$wt_path")" || pr=""
        if [ -n "$pr" ]; then
            V_PR="#${pr}"
        fi
    fi

    local new
    new="$(render_template "$template")"
    new="$(trim "$new")"
    # Path-style templates ({repo}/{branch}) degrade gracefully when a
    # component is missing: collapse duplicate slashes, then trim edges.
    new="$(printf '%s' "$new" | sed -E 's#/{2,}#/#g; s#^/+##; s#/+$##')"
    new="${new:0:LABEL_MAX}"
    new="$(trim "$new")"

    record_cwd "$ws_id" "$cwd"

    local decision
    decision="$(decide_rename "$kind" "$ws_id" "$current" "$new")"

    # Never set a blank label, even when the guard would allow a rename.
    # decide_rename has already run, so the observed label is recorded as the
    # birth label either way.
    if [ -z "$new" ]; then
        return 0
    fi
    if [ "$decision" != "rename" ]; then
        return 0
    fi

    if ! run_herdr workspace rename "$ws_id" "$new" >/dev/null 2>&1; then
        printf 'workspace-auto-rename: rename failed for %s\n' "$ws_id" >&2
        return 1
    fi
    record_applied "$ws_id" "$new"
    return 0
}
