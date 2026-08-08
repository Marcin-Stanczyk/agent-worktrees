#!/usr/bin/env bash
#
# agent-worktrees — test suite.
#
# Plain bash, no bats, no assertion library: the tool itself refuses to depend on
# anything you have to install first, and a test suite that breaks that promise
# would not be run by the people most likely to find bugs.
#
#   test/run.sh            every scenario
#   test/run.sh wrapper    only the scenarios whose name contains "wrapper"
#
# Written for bash 3.2 (no associative arrays, no `${x^^}`) because that is what
# macOS ships and what the tool supports. CI should run it under both.
#
# EVERY scenario runs with AGENT_WORKTREES_NO_HERDR=1 and its own HOME. Without
# the first, the suite rearranges the panes of whoever is working in herdr right
# now; without the second, it writes symlinks into the real ~/.claude/projects.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
AWT_SH="$ROOT/agent-worktrees.sh"
FUNC_SH="$ROOT/awt.sh"

FILTER="${1:-}"
PASS=0; FAIL=0; SKIP=0
FAILED_NAMES=""

red()   { printf '\033[0;31m%s\033[0m\n' "$1"; }
green() { printf '\033[0;32m%s\033[0m\n' "$1"; }
dim()   { printf '\033[0;90m%s\033[0m\n' "$1"; }

# --------------------------------------------------------------------------
# Assertions. Each records a failure and returns 1 so a scenario can stop early,
# but never exits — one broken scenario must not hide the twenty after it.
# --------------------------------------------------------------------------
CURRENT=""
fail() { FAIL=$((FAIL + 1)); FAILED_NAMES="$FAILED_NAMES
  - $CURRENT: $1"; red "    ✗ $1"; return 1; }

assert_eq() { # want got label
    [ "$1" = "$2" ] && return 0
    fail "$3: want [$1], got [$2]"
}
assert_contains() { # haystack needle label
    case "$1" in *"$2"*) return 0 ;; esac
    fail "$3: [$2] not found in: $(printf '%s' "$1" | head -3 | tr '\n' '|')"
}
assert_not_contains() {
    case "$1" in *"$2"*) fail "$3: [$2] should NOT be there"; return 1 ;; esac
    return 0
}
assert_dir()    { [ -d "$1" ] && return 0; fail "$2: no such directory: $1"; }
assert_no_dir() { [ ! -d "$1" ] && return 0; fail "$2: directory should be gone: $1"; }

# --------------------------------------------------------------------------
# Fixtures
# --------------------------------------------------------------------------
# A bare repository plus a clone, so `origin/<branch>` is real rather than
# simulated. Branch checks in the tool go through `rev-parse origin/x`, which a
# fixture without a true remote would answer wrongly.
make_repo() { # name branch...
    local name="$1"; shift
    local d="$TMP/$name"
    mkdir -p "$d"
    git init -q --bare "$d/origin.git"
    git clone -q "$d/origin.git" "$d/work" 2>/dev/null
    (
        cd "$d/work" || exit 1
        git config user.email t@example.com
        git config user.name "Test"
        git config commit.gpgsign false
        echo "fixture" > README.md
        git add -A && git commit -qm "init"
        local first="$1"; shift
        git branch -M "$first"
        git push -q -u origin "$first"
        local b
        for b in "$@"; do
            git checkout -qb "$b"
            git push -q -u origin "$b"
        done
        git checkout -q "$first"
    )
    printf '%s\n' "$d/work"
}

# The tool, always with herdr disabled and a throwaway HOME.
awt_run() { # dir args...
    local d="$1"; shift
    ( cd "$d" && AGENT_WORKTREES_NO_HERDR=1 HOME="$FAKE_HOME" \
        "$BASH_UNDER_TEST" "$AWT_SH" "$@" )
}

scenario() {
    CURRENT="$1"
    case "$CURRENT" in
        *"$FILTER"*) ;;
        *) SKIP=$((SKIP + 1)); return 1 ;;
    esac
    dim "  · $CURRENT"
    return 0
}
done_ok() { PASS=$((PASS + 1)); }

# ==========================================================================
# SCENARIOS
# ==========================================================================

t_new_with_explicit_base() {
    scenario "new: explicit base creates the worktree and prints only the path" || return 0
    local repo; repo="$(make_repo r1 main develop)"
    local out err rc
    out="$(awt_run "$repo" new alpha develop 2>"$TMP/e")"; rc=$?
    err="$(cat "$TMP/e")"
    assert_eq 0 "$rc" "exit code" || return 0
    assert_eq 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "stdout is one line" || return 0
    assert_dir "$out" "worktree directory" || return 0
    assert_eq "session/alpha" \
        "$(git -C "$out" rev-parse --abbrev-ref HEAD)" "branch name" || return 0
    assert_contains "$err" "Session alpha ready" "human output goes to stderr" || return 0
    done_ok
}

t_new_without_base() {
    # THE REGRESSION THIS SUITE EXISTS FOR.
    # `default_base` was `detect_bases | head -1`; head closed the pipe, the
    # producer took SIGPIPE, pipefail turned that into 141 and set -e ended the
    # script in silence. `new <name>` therefore failed in EVERY repository, and
    # the survey hid it because it reads the same function through a process
    # substitution, where the status is thrown away.
    scenario "new: no base given falls back to the default one (SIGPIPE regression)" || return 0
    local repo; repo="$(make_repo r2 main develop)"
    local out rc err
    out="$(awt_run "$repo" new beta 2>"$TMP/e")"; rc=$?
    err="$(cat "$TMP/e")"
    assert_eq 0 "$rc" "exit code (141 = SIGPIPE regression)" || return 0
    assert_dir "$out" "worktree directory" || return 0
    assert_contains "$err" "off origin/develop" "picked the first detected base" || return 0
    done_ok
}

t_new_hotfix() {
    scenario "new: cutting off the release branch names the branch hotfix/" || return 0
    local repo; repo="$(make_repo r3 main develop)"
    local out err
    out="$(awt_run "$repo" new urgent main 2>"$TMP/e")"
    err="$(cat "$TMP/e")"
    assert_eq "hotfix/urgent" \
        "$(git -C "$out" rev-parse --abbrev-ref HEAD)" "branch name" || return 0
    assert_contains "$err" "MERGE THIS FIX BACK" "warns about merging back" || return 0
    done_ok
}

t_new_twice() {
    scenario "new: an existing session is entered, not recreated" || return 0
    local repo; repo="$(make_repo r4 main develop)"
    local first second err
    first="$(awt_run "$repo" new gamma develop 2>/dev/null)"
    second="$(awt_run "$repo" new gamma develop 2>"$TMP/e")"
    err="$(cat "$TMP/e")"
    assert_eq "$first" "$second" "same directory returned" || return 0
    assert_contains "$err" "already exists" "says so" || return 0
    done_ok
}

t_new_bad_base() {
    scenario "new: a base that does not exist fails loudly" || return 0
    local repo; repo="$(make_repo r5 main develop)"
    local err rc
    awt_run "$repo" new delta nonexistent >/dev/null 2>"$TMP/e"; rc=$?
    err="$(cat "$TMP/e")"
    assert_eq 1 "$rc" "exit code" || return 0
    assert_contains "$err" "No such base" "explains why" || return 0
    done_ok
}

t_no_origin() {
    # Used to be a silent exit 1: the fetch failed, set -e ended the script and
    # nothing was printed at all.
    scenario "no origin: both entry points say what is wrong" || return 0
    local d="$TMP/lonely"
    mkdir -p "$d"
    (
        cd "$d" && git init -q && git config user.email t@example.com \
            && git config user.name Test && git config commit.gpgsign false \
            && echo x > a && git add -A && git commit -qm init
    )
    local rc err
    awt_run "$d" new omega >/dev/null 2>"$TMP/e"; rc=$?
    err="$(cat "$TMP/e")"
    assert_eq 1 "$rc" "new: exit code" || return 0
    assert_contains "$err" "no remote called 'origin'" "new: names the problem" || return 0
    assert_contains "$err" "git remote add origin" "new: says how to fix it" || return 0

    printf '\n' | awt_run "$d" start >/dev/null 2>"$TMP/e2"
    assert_contains "$(cat "$TMP/e2")" "no remote called 'origin'" \
        "start: names the problem" || return 0
    done_ok
}

t_outside_repo() {
    scenario "outside a repository: refuses with an explanation" || return 0
    local d="$TMP/not-a-repo"; mkdir -p "$d"
    local rc err
    ( cd "$d" && AGENT_WORKTREES_NO_HERDR=1 HOME="$FAKE_HOME" \
        "$BASH_UNDER_TEST" "$AWT_SH" list ) >/dev/null 2>"$TMP/e"; rc=$?
    err="$(cat "$TMP/e")"
    assert_eq 1 "$rc" "exit code" || return 0
    assert_contains "$err" "Not inside a git repository" "explains" || return 0
    done_ok
}

t_config() {
    scenario "config: bases and release are read, a wrong entry warns and is skipped" || return 0
    local repo; repo="$(make_repo r6 main develop staging)"
    printf 'bases = staging, nosuchbranch, main\nrelease = main\n' \
        > "$repo/.agent-worktrees.conf"
    local out err
    out="$(awt_run "$repo" new epsilon 2>"$TMP/e")"
    err="$(cat "$TMP/e")"
    assert_contains "$err" "nosuchbranch" "warns about the bogus entry" || return 0
    assert_contains "$err" "off origin/staging" "used the first valid configured base" || return 0
    assert_eq "session/epsilon" \
        "$(git -C "$out" rev-parse --abbrev-ref HEAD)" "not a hotfix" || return 0
    done_ok
}

t_protocol() {
    scenario "wrapper protocol: one field per line, arguments kept separate" || return 0
    local repo; repo="$(make_repo r7 main develop)"
    printf 'agent_args = --add-dir ../sibling --verbose\n' > "$repo/.agent-worktrees.conf"
    mkdir -p "$TMP/bin"
    printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/claude"; chmod +x "$TMP/bin/claude"
    local out
    out="$( cd "$repo" && printf '1\nproto\n1\n\n' | \
        AGENT_WORKTREES_NO_HERDR=1 HOME="$FAKE_HOME" AWT_WRAPPER=1 \
        PATH="$TMP/bin:$PATH" "$BASH_UNDER_TEST" "$AWT_SH" start 2>/dev/null )"
    assert_eq 5 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" \
        "5 lines: dir, agent, 3 arguments" || return 0
    assert_eq "claude" "$(printf '%s\n' "$out" | sed -n 2p)" "line 2 is the agent" || return 0
    assert_eq "--add-dir" "$(printf '%s\n' "$out" | sed -n 3p)" "line 3 is the first flag" || return 0
    assert_eq "../sibling" "$(printf '%s\n' "$out" | sed -n 4p)" "line 4 is its value" || return 0
    assert_not_contains "$(printf '%s\n' "$out" | sed -n 1p)" "	" "no tabs left in the path" || return 0
    done_ok
}

# The wrapper is exercised against a STUB tool rather than the real one: this is
# a test of the parsing, and it has to cover a field the real tool cannot
# currently produce — an argument containing a space — because the protocol
# promises it and a future config format may well deliver it.
t_wrapper_shell() { # shell
    local sh="$1"
    scenario "wrapper: awt() parses the protocol correctly in $sh" || return 0
    command -v "$sh" >/dev/null 2>&1 || { dim "    (no $sh here — skipped)"; SKIP=$((SKIP + 1)); return 0; }

    local d="$TMP/wrap-$sh"; mkdir -p "$d/target"
    cat > "$d/stub" <<STUB
#!/bin/sh
printf '%s\n' "$d/target" "$d/agent" "--add-dir" "one two" "--last"
STUB
    chmod +x "$d/stub"
    cat > "$d/agent" <<'AGENT'
#!/bin/sh
printf '%s\n' "$@" > "$(dirname "$0")/argv"
pwd > "$(dirname "$0")/cwd"
AGENT
    chmod +x "$d/agent"

    "$sh" -c ". '$FUNC_SH'; AWT_CLI='$d/stub' awt start" >/dev/null 2>"$TMP/e"
    assert_eq "" "$(cat "$TMP/e")" "no shell errors (e.g. bad substitution)" || return 0
    assert_eq "--add-dir
one two
--last" "$(cat "$d/argv" 2>/dev/null)" "three arguments, the middle one intact" || return 0
    assert_eq "$(cd "$d/target" && pwd)" "$(cat "$d/cwd" 2>/dev/null)" "cd happened" || return 0
    done_ok
}

t_wrapper_plain_shell() {
    scenario "wrapper: 'plain shell' changes directory and starts nothing" || return 0
    local d="$TMP/wrap-plain"; mkdir -p "$d/target"
    cat > "$d/stub" <<STUB
#!/bin/sh
printf '%s\n' "$d/target" "plain shell"
STUB
    chmod +x "$d/stub"
    local out
    out="$(bash -c ". '$FUNC_SH'; AWT_CLI='$d/stub' awt start; pwd" 2>&1)"
    assert_eq "$(cd "$d/target" && pwd)" "$out" "ends up in the session, no agent run" || return 0
    done_ok
}

t_wrapper_passthrough() {
    scenario "wrapper: any other subcommand is passed straight through" || return 0
    local d="$TMP/wrap-pass"; mkdir -p "$d"
    printf '#!/bin/sh\nprintf "got:%%s\\n" "$*"\n' > "$d/stub"; chmod +x "$d/stub"
    assert_eq "got:list" \
        "$(bash -c ". '$FUNC_SH'; AWT_CLI='$d/stub' awt list" 2>&1)" "list" || return 0
    done_ok
}

t_wrapper_failure() {
    scenario "wrapper: a failing tool does not cd anywhere" || return 0
    local d="$TMP/wrap-fail"; mkdir -p "$d"
    printf '#!/bin/sh\nexit 3\n' > "$d/stub"; chmod +x "$d/stub"
    local before out
    before="$(cd "$TMP" && pwd)"
    out="$(cd "$TMP" && bash -c ". '$FUNC_SH'; AWT_CLI='$d/stub' awt start; echo rc=\$?; pwd" 2>&1)"
    assert_contains "$out" "rc=1" "returns non-zero" || return 0
    assert_contains "$out" "$before" "stayed put" || return 0
    done_ok
}

t_clean() {
    scenario "clean: removes untouched sessions, keeps work" || return 0
    local repo; repo="$(make_repo r8 main develop)"
    local empty dirty committed
    empty="$(awt_run "$repo" new empty develop 2>/dev/null)"
    dirty="$(awt_run "$repo" new dirty develop 2>/dev/null)"
    committed="$(awt_run "$repo" new committed develop 2>/dev/null)"
    echo "uncommitted" > "$dirty/scratch.txt"
    (
        cd "$committed" && git config user.email t@example.com && git config user.name Test \
            && git config commit.gpgsign false \
            && echo work > work.txt && git add work.txt && git commit -qm "real work"
    )
    local err
    awt_run "$repo" clean >/dev/null 2>"$TMP/e"
    err="$(cat "$TMP/e")"
    assert_no_dir "$empty" "the untouched one is gone" || return 0
    assert_dir "$dirty" "the dirty one is kept" || return 0
    assert_dir "$committed" "the one with commits is kept" || return 0
    assert_contains "$err" "removed 1" "reports one removal" || return 0
    done_ok
}

t_read_only_commands() {
    scenario "list / where / rehearse / verify all succeed and change nothing" || return 0
    local repo; repo="$(make_repo r9 main develop)"
    local session; session="$(awt_run "$repo" new zeta develop 2>/dev/null)"
    local before after c rc out
    before="$(git -C "$repo" worktree list | wc -l | tr -d ' ')"
    for c in list where rehearse verify; do
        out="$(awt_run "$repo" "$c" 2>&1)"; rc=$?
        assert_eq 0 "$rc" "$c exits 0" || return 0
    done
    out="$(awt_run "$session" where 2>&1)"
    assert_contains "$out" "session/zeta" "where names the branch from inside a session" || return 0
    after="$(git -C "$repo" worktree list | wc -l | tr -d ' ')"
    assert_eq "$before" "$after" "no worktree was added or removed" || return 0
    done_ok
}

t_same_branch_lock() {
    scenario "isolation: git refuses the same branch in two worktrees" || return 0
    local repo; repo="$(make_repo r10 main develop)"
    local session; session="$(awt_run "$repo" new eta develop 2>/dev/null)"
    if git -C "$repo" worktree add "$TMP/steal" session/eta >/dev/null 2>&1; then
        fail "the lock did not hold — session/eta was checked out twice"
        return 0
    fi
    done_ok
}

t_memory_symlink() {
    scenario "memory: a session's agent memory is symlinked to the main project's" || return 0
    local repo; repo="$(make_repo r11 main develop)"
    local key
    key="$(printf '%s' "$repo" | tr '/_' '--')"
    mkdir -p "$FAKE_HOME/.claude/projects/$key"
    echo "remembered" > "$FAKE_HOME/.claude/projects/$key/note.txt"
    local session; session="$(awt_run "$repo" new theta develop 2>/dev/null)"
    local skey; skey="$(printf '%s' "$session" | tr '/_' '--')"
    [ -L "$FAKE_HOME/.claude/projects/$skey" ] || { fail "no symlink for the session"; return 0; }
    assert_eq "remembered" \
        "$(cat "$FAKE_HOME/.claude/projects/$skey/note.txt" 2>/dev/null)" \
        "the session sees the main project's memory" || return 0
    done_ok
}

t_no_herdr_flag() {
    scenario "herdr: AGENT_WORKTREES_NO_HERDR makes verify report it as absent" || return 0
    local repo; repo="$(make_repo r12 main develop)"
    assert_contains "$(awt_run "$repo" verify 2>&1)" "not in PATH" \
        "verify degrades instead of failing" || return 0
    done_ok
}

# ==========================================================================
# RUNNER
# ==========================================================================
BASH_UNDER_TEST="${BASH_UNDER_TEST:-bash}"
# `pwd -P` on purpose. On macOS $TMPDIR lives under /var, which is a symlink to
# /private/var, and the tool resolves its own paths physically — so a fixture path
# kept in logical form silently fails to match anything the tool reports.
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/awt-test.XXXXXX")" && pwd -P)"
FAKE_HOME="$TMP/home"; mkdir -p "$FAKE_HOME"
trap 'rm -rf "$TMP"' EXIT

printf '\n'
dim "agent-worktrees test suite"
dim "  script:  $AWT_SH"
dim "  bash:    $("$BASH_UNDER_TEST" --version | head -1)"
dim "  sandbox: $TMP"
[ -n "$FILTER" ] && dim "  filter:  $FILTER"
printf '\n'

t_new_with_explicit_base
t_new_without_base
t_new_hotfix
t_new_twice
t_new_bad_base
t_no_origin
t_outside_repo
t_config
t_protocol
t_wrapper_shell bash
t_wrapper_shell zsh
t_wrapper_plain_shell
t_wrapper_passthrough
t_wrapper_failure
t_clean
t_read_only_commands
t_same_branch_lock
t_memory_symlink
t_no_herdr_flag

printf '\n'
if [ "$FAIL" -eq 0 ]; then
    green "$PASS passed, $SKIP skipped, 0 failed"
    exit 0
else
    red "$PASS passed, $SKIP skipped, $FAIL FAILED"
    printf '%s\n' "$FAILED_NAMES"
    exit 1
fi
