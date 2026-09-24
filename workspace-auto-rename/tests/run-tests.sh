#!/usr/bin/env bash
# tests/run-tests.sh: unit and scenario tests for workspace-auto-rename.
#
# Runs entirely offline against tests/fake-herdr; never talks to a live
# herdr server.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

t() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass=$((pass + 1))
        printf 'ok   %s\n' "$name"
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n     expected: %q\n     actual:   %q\n' "$name" "$expected" "$actual"
    fi
}

# Run a snippet with hooks/lib.sh sourced, isolated from this shell.
libeval() {
    bash -c 'source "$1"; shift; eval "$*"' lib "$ROOT/hooks/lib.sh" "$@"
}

reset_env() {
    rm -rf "$TMP/cfg" "$TMP/state" "$TMP/fake"
    mkdir -p "$TMP/cfg" "$TMP/state" "$TMP/fake"
    export HERDR_PLUGIN_CONFIG_DIR="$TMP/cfg"
    export HERDR_PLUGIN_STATE_DIR="$TMP/state"
    export FAKE_HERDR_DIR="$TMP/fake"
    export HERDR_BIN_PATH="$ROOT/tests/fake-herdr"
    # Default to a nonexistent gh so tests never hit a real GitHub API,
    # even when gh is installed on this machine.
    export GH_BIN="$TMP/gh-missing"
    unset HERDR_PLUGIN_EVENT HERDR_PLUGIN_EVENT_JSON HERDR_PLUGIN_CONTEXT_JSON HERDR_WORKSPACE_ID
    unset GH_CALL_LOG GH_RESPONSE_FILE
}

write_config() {
    printf '%s\n' "$@" > "$HERDR_PLUGIN_CONFIG_DIR/config.toml"
}

fixture() {
    printf '%s' "$2" > "$FAKE_HERDR_DIR/$1"
}

mk_ctx() { # id label cwd [repo]
    local id="$1" label="$2" cwd="$3" repo="${4:-}"
    jq -nc --arg id "$id" --arg label "$label" --arg cwd "$cwd" --arg repo "$repo" \
        '{workspace_id: $id, workspace_label: $label, workspace_cwd: $cwd,
          worktree: (if $repo == "" then null else {repo_name: $repo} end)}'
}

mk_evt_wtcreate() { # id label number branch wtpath repo
    jq -nc --arg id "$1" --arg label "$2" --arg num "$3" --arg branch "$4" \
        --arg path "$5" --arg repo "$6" \
        '{event: "worktree.created",
          data: {workspace: {workspace_id: $id, number: ($num | tonumber), label: $label,
                             worktree: {repo_name: $repo, checkout_path: $path}},
                 worktree: {path: $path, branch: $branch}}}'
}

mk_evt_wscreate() { # id label number
    jq -nc --arg id "$1" --arg label "$2" --arg num "$3" \
        '{event: "workspace.created",
          data: {workspace: {workspace_id: $id, number: ($num | tonumber), label: $label}}}'
}

mk_evt_agent() { # id agent
    jq -nc --arg id "$1" --arg agent "$2" \
        '{event: "pane.agent_detected",
          data: {pane_id: ($id + ":p1"), workspace_id: $id, agent: $agent, released: false}}'
}

run_hook() { # event evtjson ctxjson
    HERDR_PLUGIN_EVENT="$1" HERDR_PLUGIN_EVENT_JSON="$2" HERDR_PLUGIN_CONTEXT_JSON="$3" \
        bash "$ROOT/hooks/on-event.sh"
}

run_startup() {
    bash "$ROOT/hooks/rename-existing.sh"
}

rename_count() {
    if [ -f "$FAKE_HERDR_DIR/renames.tsv" ]; then
        wc -l < "$FAKE_HERDR_DIR/renames.tsv" | tr -d ' '
    else
        printf '0'
    fi
}

last_rename() {
    tail -n 1 "$FAKE_HERDR_DIR/renames.tsv" 2>/dev/null || true
}

read_state() {
    cat "$HERDR_PLUGIN_STATE_DIR/$1" 2>/dev/null || true
}

repeat_char() {
    printf "$1%.0s" $(seq 1 "$2")
}

mk_gh_stub() { # response-json
    cat > "$TMP/fake-gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALL_LOG"
resp="$(cat "$GH_RESPONSE_FILE")"
# Apply the --jq filter the way the real gh CLI would.
filter="."
prev=""
for a in "$@"; do
    if [ "$prev" = "--jq" ]; then
        filter="$a"
    fi
    prev="$a"
done
printf '%s' "$resp" | jq -r "$filter"
EOF
    chmod +x "$TMP/fake-gh"
    printf '%s' "$1" > "$TMP/pr-response.json"
    : > "$TMP/gh-calls.log"
    export GH_BIN="$TMP/fake-gh"
    export GH_CALL_LOG="$TMP/gh-calls.log"
    export GH_RESPONSE_FILE="$TMP/pr-response.json"
}

gh_call_count() {
    if [ -f "$TMP/gh-calls.log" ]; then
        wc -l < "$TMP/gh-calls.log" | tr -d ' '
    else
        printf '0'
    fi
}

# ---------------------------------------------------------------- unit tests

reset_env
write_config \
    'template = "{repo-name}/{branch}"' \
    'template-no-git = "{cwd-basename}"' \
    '# a comment line' \
    'only-rename-unmodified = false'
cfg="$HERDR_PLUGIN_CONFIG_DIR/config.toml"
t "config_get template" "{repo-name}/{branch}" "$(libeval "config_get '$cfg' template")"
t "config_get no-git" "{cwd-basename}" "$(libeval "config_get '$cfg' template-no-git")"
t "config_get missing key" "" "$(libeval "config_get '$cfg' does-not-exist")"

t "render repo/branch" "demo-repo/feature-x" \
    "$(libeval 'V_REPO_NAME=demo-repo; V_BRANCH=feature-x; render_template "{repo-name}/{branch}"')"
t "render unknown var to empty" "" "$(libeval 'render_template "{nope}"')"
t "render literal passthrough" "hello world" "$(libeval 'render_template "hello world"')"
# shellcheck disable=SC2016  # snippet is intentionally single-quoted for libeval
t "render cwd-basename" "proj" \
    "$(libeval 'V_CWD_BASENAME=$(basename_of "/a/b/proj/"); render_template "{cwd-basename}"')"
t "trim" "x" "$(libeval 'trim "  x  "')"

# Repo alias table parsing and lookup.
reset_env
cfg="$HERDR_PLUGIN_CONFIG_DIR/config.toml"
write_config 'template = "{repo-name}"' '[repo-alias]' 'demo-repo = "DR"' '[other]' 'foo = "F"'
t "alias section parsed" "DR" "$(libeval "load_repo_aliases '$cfg'; repo_alias demo-repo")"
t "alias unmapped raw" "other-repo" "$(libeval "load_repo_aliases '$cfg'; repo_alias other-repo")"
t "alias ignores other sections" "foo" "$(libeval "load_repo_aliases '$cfg'; repo_alias foo")"
t "alias empty name" "" "$(libeval "load_repo_aliases '$cfg'; repo_alias ''")"

# Branch-name PR patterns.
t "pattern pr-123" "123" "$(libeval 'pr_from_branch_pattern pr-123')"
t "pattern pr/123" "123" "$(libeval 'pr_from_branch_pattern pr/123')"
t "pattern pr123" "123" "$(libeval 'pr_from_branch_pattern pr123')"
t "pattern pr-123-desc" "123" "$(libeval 'pr_from_branch_pattern pr-123-short-description')"
t "pattern 1234-fix-thing" "1234" "$(libeval 'pr_from_branch_pattern 1234-fix-thing')"
t "pattern bare 1234" "1234" "$(libeval 'pr_from_branch_pattern 1234')"
t "pattern no match" "" "$(libeval 'pr_from_branch_pattern feature-x')"
t "pattern no match pr-abc" "" "$(libeval 'pr_from_branch_pattern pr-abc')"

# Clamp to 80 chars via apply_rename against the fake CLI.
reset_env
write_config 'template = "{branch}"'
long_branch="$(repeat_char b 100)"
libeval "load_config; apply_rename creation w9 workspace 9 '$long_branch' '' '' '' ''"
t "clamp to 80 chars" "w9	$(repeat_char b 80)" "$(last_rename)"

# Missing components collapse instead of producing "//" or a leading "/".
reset_env
write_config 'template = "{repo-name}/{branch}"'
libeval "load_config; apply_rename creation w11 workspace 11 '' '' '' '' ''"
t "empty render skips rename" "0" "$(rename_count)"
libeval "load_config; apply_rename creation w12 workspace 12 main '' '' '' ''"
t "leading slash collapsed" "w12	main" "$(last_rename)"

# ------------------------------------------------------- scenario tests

# S1: first creation event renames and records birth + applied labels.
reset_env
write_config 'template = "{repo-name}/{branch}"'
fixture ws-get.json '{"result":{"workspace_id":"w2","number":2,"label":"workspace"}}'
fixture wt-w2.json '{"result":{"worktrees":[{"path":"/tmp/wt/demo-repo/feature","branch":"feature-x","open_workspace_id":"w2"}]}}'
fixture agent-list.json '{"result":{"agents":[{"agent":"pi","workspace_id":"w2","cwd":"/home/lucas/source/demo-repo"}]}}'
run_hook worktree.created \
    "$(mk_evt_wtcreate w2 workspace 2 feature-x /tmp/wt/demo-repo/feature demo-repo)" \
    "$(mk_ctx w2 workspace /tmp/wt/demo-repo/feature demo-repo)"
t "S1 renames on creation" "w2	demo-repo/feature-x" "$(last_rename)"
t "S1 single rename" "1" "$(rename_count)"
t "S1 birth recorded" "workspace" "$(read_state birth-w2)"
t "S1 applied recorded" "demo-repo/feature-x" "$(read_state applied-w2)"

# S2: rerun with the label already equal to the rendered target: no-op.
run_hook worktree.created \
    "$(mk_evt_wtcreate w2 workspace 2 feature-x /tmp/wt/demo-repo/feature demo-repo)" \
    "$(mk_ctx w2 demo-repo/feature-x /tmp/wt/demo-repo/feature demo-repo)"
t "S2 idempotent rerun" "1" "$(rename_count)"

# S3: manual user rename is respected.
run_hook worktree.created \
    "$(mk_evt_wtcreate w2 workspace 2 feature-x /tmp/wt/demo-repo/feature demo-repo)" \
    "$(mk_ctx w2 my-custom-name /tmp/wt/demo-repo/feature demo-repo)"
t "S3 manual rename respected" "1" "$(rename_count)"

# S4: template change re-renders when the current label is one we applied.
write_config 'template = "{branch}"'
run_hook worktree.created \
    "$(mk_evt_wtcreate w2 workspace 2 feature-x /tmp/wt/demo-repo/feature demo-repo)" \
    "$(mk_ctx w2 demo-repo/feature-x /tmp/wt/demo-repo/feature demo-repo)"
t "S4 re-render on template change" "w2	feature-x" "$(last_rename)"
t "S4 rename count" "2" "$(rename_count)"

# S5: only-rename-unmodified=false overrides a manual rename.
write_config 'template = "{branch}"' 'only-rename-unmodified = false'
run_hook worktree.created \
    "$(mk_evt_wtcreate w2 workspace 2 feature-x /tmp/wt/demo-repo/feature demo-repo)" \
    "$(mk_ctx w2 my-custom-name /tmp/wt/demo-repo/feature demo-repo)"
t "S5 guard disabled forces rename" "w2	feature-x" "$(last_rename)"

# S6: rename-on-agent-detect=false makes agent detection a no-op.
reset_env
write_config 'template = "{repo-name}/{branch}"' 'rename-on-agent-detect = false'
fixture agent-list.json '{"result":{"agents":[{"agent":"pi","workspace_id":"w3","cwd":"/home/lucas/proj"}]}}'
run_hook pane.agent_detected "$(mk_evt_agent w3 pi)" "$(mk_ctx w3 workspace '')"
t "S6 agent detect disabled" "0" "$(rename_count)"

# S7: agent detection fills {agent-kind} using the branch from the CLI.
reset_env
write_config 'template = "{agent-kind}/{branch}"'
fixture ws-get.json '{"result":{"workspace_id":"w2","number":2,"label":"workspace"}}'
fixture wt-w2.json '{"result":{"worktrees":[{"path":"/tmp/wt/demo-repo/feature","branch":"feature-x","open_workspace_id":"w2"}]}}'
fixture agent-list.json '{"result":{"agents":[{"agent":"pi","workspace_id":"w2","cwd":"/home/lucas/source/demo-repo"}]}}'
run_hook pane.agent_detected "$(mk_evt_agent w2 pi)" "$(mk_ctx w2 workspace '')"
t "S7 agent-kind filled" "w2	pi/feature-x" "$(last_rename)"

# S8: adopt-existing=false records but skips; a later creation event renames.
reset_env
write_config 'template = "{branch}"' 'adopt-existing = false'
fixture agent-list.json '{"result":{"agents":[{"agent":"pi","workspace_id":"w3","cwd":"/home/lucas/proj"}]}}'
run_hook pane.agent_detected "$(mk_evt_agent w3 pi)" "$(mk_ctx w3 workspace '')"
t "S8 adopt disabled skips" "0" "$(rename_count)"
t "S8 birth recorded anyway" "workspace" "$(read_state birth-w3)"
run_hook workspace.created "$(mk_evt_wscreate w3 workspace 3)" "$(mk_ctx w3 workspace '')"
t "S8 creation event renames" "w3	proj" "$(last_rename)"

# S9: no config.toml means the plugin is completely inert.
reset_env
run_hook worktree.created \
    "$(mk_evt_wtcreate w2 workspace 2 feature-x /tmp/wt/demo-repo/feature demo-repo)" \
    "$(mk_ctx w2 workspace /tmp/wt/demo-repo/feature demo-repo)"
t "S9 inert without config" "0" "$(rename_count)"
if [ -f "$FAKE_HERDR_DIR/renames.tsv" ]; then
    t "S9 no renames file created" "absent" "present"
else
    t "S9 no renames file created" "absent" "absent"
fi

# S10: startup adopts never-seen workspaces by default; empty renders skip.
reset_env
write_config 'template = "{repo-name}/{branch}"'
fixture ws-list.json '{"result":{"workspaces":[{"workspace_id":"w5","number":5,"label":"workspace"},{"workspace_id":"w6","number":6,"label":"my-custom"}]}}'
fixture wt-w5.json '{"result":{"worktrees":[{"path":"/tmp/wt/demo-repo/main","branch":"main","open_workspace_id":"w5"}]}}'
fixture agent-list.json '{"result":{"agents":[{"agent":"pi","workspace_id":"w5","cwd":"/nonexistent-dir"}]}}'
run_startup
t "S10 startup renames w5" "w5	main" "$(last_rename)"
t "S10 only w5 renamed" "1" "$(rename_count)"
t "S10 w6 birth recorded" "my-custom" "$(read_state birth-w6)"

# S11: startup with adopt-existing=false records only.
reset_env
write_config 'template = "{branch}"' 'adopt-existing = false'
fixture ws-list.json '{"result":{"workspaces":[{"workspace_id":"w5","number":5,"label":"workspace"}]}}'
fixture wt-w5.json '{"result":{"worktrees":[{"path":"/tmp/wt/demo-repo/main","branch":"main","open_workspace_id":"w5"}]}}'
run_startup
t "S11 adopt-disabled startup skips" "0" "$(rename_count)"
t "S11 birth recorded" "workspace" "$(read_state birth-w5)"

# ------------------------------------------------ repo alias + PR scenarios

# P1: alias from [repo-alias] replaces {repo-name} through the hook path.
reset_env
write_config 'template = "{repo-name}"' '[repo-alias]' 'demo-repo = "DR"'
run_hook worktree.created \
    "$(mk_evt_wtcreate w2 workspace 2 feature-x /tmp/wt/demo-repo/feature demo-repo)" \
    "$(mk_ctx w2 workspace /tmp/wt/demo-repo/feature demo-repo)"
t "P1 alias applied" "w2	DR" "$(last_rename)"

# P2: unmapped repos keep the raw name.
reset_env
write_config 'template = "{repo-name}"'
run_hook worktree.created \
    "$(mk_evt_wtcreate w2 workspace 2 feature-x /tmp/wt/other-repo/feature other-repo)" \
    "$(mk_ctx w2 workspace /tmp/wt/other-repo/feature other-repo)"
t "P2 unmapped keeps raw" "w2	other-repo" "$(last_rename)"

# P3: {pr} with a branch that encodes the PR number; no gh needed.
reset_env
write_config 'template = "{repo-name} {pr}"'
run_hook worktree.created \
    "$(mk_evt_wtcreate w2 workspace 2 pr-123 /tmp/wt/demo-repo/pr-123 demo-repo)" \
    "$(mk_ctx w2 workspace /tmp/wt/demo-repo/pr-123 demo-repo)"
t "P3 pattern PR rendered" "w2	demo-repo #123" "$(last_rename)"

# P4: branch with no PR and gh unavailable: suffix drops, no trailing space.
reset_env
write_config 'template = "{repo-name} {pr}"'
run_hook worktree.created \
    "$(mk_evt_wtcreate w2 workspace 2 feature-x /tmp/wt/demo-repo/feature demo-repo)" \
    "$(mk_ctx w2 workspace /tmp/wt/demo-repo/feature demo-repo)"
t "P4 no PR drops suffix" "w2	demo-repo" "$(last_rename)"

# P5: gh fallback resolves the PR for a plain branch name.
reset_env
mkdir -p "$TMP/wtdir"
mk_gh_stub '[{"number":42}]'
write_config 'template = "{repo-name} {pr}"'
run_hook worktree.created \
    "$(mk_evt_wtcreate w2 workspace 2 feature-x "$TMP/wtdir" demo-repo)" \
    "$(mk_ctx w2 workspace "$TMP/wtdir" demo-repo)"
t "P5 gh fallback PR" "w2	demo-repo #42" "$(last_rename)"
t "P5 gh invoked once" "1" "$(gh_call_count)"
t "P5 cache written" "42" "$(cat "$HERDR_PLUGIN_STATE_DIR"/pr-cache/* 2>/dev/null)"

# P6: a repeat event for the same branch is served from cache, not gh.
run_hook worktree.created \
    "$(mk_evt_wtcreate w2 workspace 2 feature-x "$TMP/wtdir" demo-repo)" \
    "$(mk_ctx w2 workspace "$TMP/wtdir" demo-repo)"
t "P6 cache avoids gh" "1" "$(gh_call_count)"
t "P6 rename still applied" "2" "$(rename_count)"

# P7: a miss (no PR found) is negative-cached too.
reset_env
mkdir -p "$TMP/wtdir"
mk_gh_stub '[]'
write_config 'template = "{repo-name} {pr}"'
run_hook worktree.created \
    "$(mk_evt_wtcreate w2 workspace 2 feature-x "$TMP/wtdir" demo-repo)" \
    "$(mk_ctx w2 workspace "$TMP/wtdir" demo-repo)"
t "P7 miss drops suffix" "w2	demo-repo" "$(last_rename)"
t "P7 miss invokes gh once" "1" "$(gh_call_count)"
t "P7 negative cache written" "none" "$(cat "$HERDR_PLUGIN_STATE_DIR"/pr-cache/* 2>/dev/null)"
run_hook worktree.created \
    "$(mk_evt_wtcreate w2 workspace 2 feature-x "$TMP/wtdir" demo-repo)" \
    "$(mk_ctx w2 workspace "$TMP/wtdir" demo-repo)"
t "P7 negative cache avoids gh" "1" "$(gh_call_count)"

# P8: no {pr} in the template means the gh lookup never runs.
reset_env
mkdir -p "$TMP/wtdir"
mk_gh_stub '[{"number":42}]'
write_config 'template = "{repo-name}/{branch}"'
run_hook worktree.created \
    "$(mk_evt_wtcreate w2 workspace 2 feature-x "$TMP/wtdir" demo-repo)" \
    "$(mk_ctx w2 workspace "$TMP/wtdir" demo-repo)"
t "P8 no {pr} no gh call" "0" "$(gh_call_count)"
t "P8 rename unaffected" "w2	demo-repo/feature-x" "$(last_rename)"

# P9: a missing gh binary renders {pr} empty without failing.
reset_env
write_config 'template = "{pr}"'
run_hook worktree.created \
    "$(mk_evt_wtcreate w2 workspace 2 feature-x /tmp/wt/demo-repo/feature demo-repo)" \
    "$(mk_ctx w2 workspace /tmp/wt/demo-repo/feature demo-repo)"
t "P9 missing gh empty render" "0" "$(rename_count)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
