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
# A WATCHDOG, BECAUSE A HANGING SUITE IS WORSE THAN A FAILING ONE
# --------------------------------------------------------------------------
# Twice while writing these tests, removing a guard turned a scenario from
# "fails" into "hangs": the survey waited on input nobody was going to give.
# A failure is a line of output; a hang is a session somebody has to notice and
# kill, and the second time it left a deliberately broken file on disk.
#
# `timeout(1)` is not on macOS, so this is the portable version: run in the
# background, poll, kill. 20 seconds is far above any real scenario here (the
# whole suite runs in seconds) and far below anybody's patience.
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-20}"

with_timeout() {
    local pid waited=0
    "$@" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$TIMEOUT_SECONDS" ]; then
            kill -9 "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$pid"
}

# --------------------------------------------------------------------------
# Fixtures
# --------------------------------------------------------------------------
# A bare repository plus a clone, so `origin/<branch>` is real rather than
# simulated. Branch checks in the tool go through `rev-parse origin/x`, which a
# fixture without a true remote would answer wrongly.
make_repo() { # name branch...
    make_repo_as "$1" work "${@:2}"
}

# The checkout's directory NAME is now part of the tool's behaviour — it decides
# what sessions are called — so the fixture has to be able to vary it.
make_repo_as() { # name checkout-dir branch...
    local name="$1" checkout="$2"; shift 2
    local d="$TMP/$name"
    mkdir -p "$d"
    git init -q --bare "$d/origin.git"
    git clone -q "$d/origin.git" "$d/$checkout" 2>/dev/null
    (
        cd "$d/$checkout" || exit 1
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
    printf '%s\n' "$d/$checkout"
}

# The tool, always with herdr disabled and a throwaway HOME.
awt_run() { # dir args...
    local d="$1"; shift
    ( cd "$d" && AGENT_WORKTREES_NO_HERDR=1 HOME="$FAKE_HOME" HERDR_PANE_ID="" \
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
    ( cd "$d" && AGENT_WORKTREES_NO_HERDR=1 HOME="$FAKE_HOME" HERDR_PANE_ID="" \
        "$BASH_UNDER_TEST" "$AWT_SH" list ) >/dev/null 2>"$TMP/e"; rc=$?
    err="$(cat "$TMP/e")"
    assert_eq 1 "$rc" "exit code" || return 0
    assert_contains "$err" "Not inside a git repository" "explains" || return 0
    done_ok
}

# THE SESSION THAT TOOK SEVEN COMMANDS.
# Reconstructed from a real attempt: `awt finanse` outside a repository, then
# `awt finanse` inside one — which printed the help on stdout and exited 0 — then
# `awt new finanse`, then a hand-derived `cd`, then the agent. Every scenario
# below is one of those steps refusing to happen again.
t_unknown_command() {
    scenario "a word that is not a command fails, on stderr, with the command that was meant" || return 0
    local repo; repo="$(make_repo u1 main develop)"
    local out err rc
    out="$(awt_run "$repo" finanse 2>"$TMP/e")"; rc=$?
    err="$(cat "$TMP/e")"
    # Exit 0 was the actual bug: a typo was indistinguishable from success.
    assert_eq 2 "$rc" "exit code" || return 0
    assert_contains "$err" "No such command: finanse" "says what is wrong" || return 0
    assert_contains "$err" "agent-worktrees new finanse" "says what was meant" || return 0
    assert_eq "" "$out" "nothing on stdout — stdout is for results" || return 0
    # The answer, not the menu: burying one line under twenty repeats the fault.
    assert_not_contains "$err" "SURVEY: asks for base" \
        "did not bury the suggestion under the whole help" || return 0
    assert_contains "$err" "agent-worktrees help" "but says where the whole help is" || return 0
    # And it must NOT have created anything on a guess.
    assert_no_dir "$(dirname "$repo")/work-session-finanse" "created nothing" || return 0
    done_ok
}

t_unknown_command_typo() {
    scenario "a mistyped subcommand is not turned into a session" || return 0
    local repo; repo="$(make_repo u2 main develop)"
    local rc
    awt_run "$repo" lst >/dev/null 2>"$TMP/e"; rc=$?
    assert_eq 2 "$rc" "exit code" || return 0
    assert_no_dir "$(dirname "$repo")/work-session-lst" "no session named after the typo" || return 0
    done_ok
}

t_unknown_flag_gets_the_list() {
    scenario "a fragment that is not a session name gets the list of commands" || return 0
    local repo; repo="$(make_repo u7 main develop)"
    local rc
    awt_run "$repo" --wat >/dev/null 2>"$TMP/e"; rc=$?
    assert_eq 2 "$rc" "exit code" || return 0
    assert_contains "$(cat "$TMP/e")" "SURVEY: asks for base" \
        "no name to guess at, so the commands are the answer" || return 0
    done_ok
}

t_help_is_asked_for() {
    scenario "help asked for goes to stdout and exits 0" || return 0
    local repo; repo="$(make_repo u3 main develop)"
    local out rc
    out="$(awt_run "$repo" help 2>"$TMP/e")"; rc=$?
    assert_eq 0 "$rc" "exit code" || return 0
    assert_contains "$out" "SURVEY" "the help is on stdout when it was requested" || return 0
    assert_eq "" "$(cat "$TMP/e")" "and nothing is complained about" || return 0
    done_ok
}

t_new_enters_the_session() {
    # `new` used to create the directory and leave you where you were, holding a
    # path to retype. It now answers the wrapper exactly as the survey does.
    scenario "new: replies with directory and agent, so the shell can enter it" || return 0
    local repo; repo="$(make_repo u4 main develop)"
    mkdir -p "$TMP/bin"
    printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/claude"; chmod +x "$TMP/bin/claude"
    local out
    out="$( cd "$repo" && AGENT_WORKTREES_NO_HERDR=1 HOME="$FAKE_HOME" HERDR_PANE_ID="" \
        AWT_WRAPPER=2 PATH="$TMP/bin:$PATH" \
        "$BASH_UNDER_TEST" "$AWT_SH" new entered develop 2>/dev/null )"
    assert_eq 2 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "two lines: dir, agent" || return 0
    assert_dir "$(printf '%s\n' "$out" | sed -n 1p)" "line 1 is the session directory" || return 0
    assert_eq "claude" "$(printf '%s\n' "$out" | sed -n 2p)" "line 2 is the agent" || return 0
    done_ok
}

t_new_without_wrapper_still_prints_a_path() {
    # The other half of the same change: scripts and CI have no shell to enter,
    # and the path on stdout is the contract they already rely on.
    scenario "new: run without the wrapper, stdout is still the path and nothing else" || return 0
    local repo; repo="$(make_repo u5 main develop)"
    local out
    out="$(awt_run "$repo" new scripted develop 2>/dev/null)"
    assert_eq 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "one line only" || return 0
    assert_dir "$out" "and it is the session directory" || return 0
    done_ok
}

t_new_stale_wrapper_refused() {
    scenario "new: an out-of-date wrapper is refused before anything is created" || return 0
    local repo; repo="$(make_repo u6 main develop)"
    local rc
    ( cd "$repo" && AGENT_WORKTREES_NO_HERDR=1 HOME="$FAKE_HOME" HERDR_PANE_ID="" \
        AWT_WRAPPER=1 "$BASH_UNDER_TEST" "$AWT_SH" new refused develop ) \
        >/dev/null 2>"$TMP/e"; rc=$?
    assert_eq 1 "$rc" "exit code" || return 0
    assert_contains "$(cat "$TMP/e")" "out of date" "says what is wrong" || return 0
    assert_no_dir "$(dirname "$repo")/work-session-refused" "created nothing first" || return 0
    done_ok
}

t_outside_repo_points_at_one() {
    # The message used to say "change into the project and try again" to somebody
    # standing in the directory that HOLDS the projects — one `cd` away, with the
    # answer on screen if only it had been printed.
    scenario "outside a repository: names the repositories one level below" || return 0
    local d="$TMP/holder"; mkdir -p "$d/alpha" "$d/notes"
    git init -q "$d/alpha"
    local err rc
    ( cd "$d" && AGENT_WORKTREES_NO_HERDR=1 HOME="$FAKE_HOME" HERDR_PANE_ID="" \
        "$BASH_UNDER_TEST" "$AWT_SH" list ) >/dev/null 2>"$TMP/e"; rc=$?
    err="$(cat "$TMP/e")"
    assert_eq 1 "$rc" "exit code" || return 0
    assert_contains "$err" "Not inside a git repository" "still says so" || return 0
    assert_contains "$err" "cd alpha" "and says where one is" || return 0
    done_ok
}

# --------------------------------------------------------------------------
# WHAT A SESSION IS CALLED, AND WHAT THAT NAME IS NO LONGER ALLOWED TO DECIDE
# --------------------------------------------------------------------------
t_naming_strips_the_base_suffix() {
    scenario "naming: a -base checkout gives <project>-<name>, not <repo>-session-<name>" || return 0
    local repo; repo="$(make_repo_as n1 kamar-base main develop)"
    local dir; dir="$(awt_run "$repo" new finanse develop 2>/dev/null)"
    assert_eq "kamar-finanse" "$(basename "$dir")" "the session directory" || return 0
    assert_dir "$dir" "and it exists" || return 0
    done_ok
}

t_naming_keeps_a_name_with_nothing_redundant() {
    scenario "naming: a repository with no such suffix keeps its whole name" || return 0
    local repo; repo="$(make_repo_as n2 agent-worktrees main develop)"
    local dir; dir="$(awt_run "$repo" new finanse develop 2>/dev/null)"
    assert_eq "agent-worktrees-finanse" "$(basename "$dir")" "nothing was stripped" || return 0
    done_ok
}

t_naming_config_overrides() {
    scenario "naming: the prefix config key settles it when the guess is wrong" || return 0
    local repo; repo="$(make_repo_as n3 weird-checkout-name main develop)"
    printf 'prefix = proj\n' > "$repo/.agent-worktrees.conf"
    local dir; dir="$(awt_run "$repo" new finanse develop 2>/dev/null)"
    assert_eq "proj-finanse" "$(basename "$dir")" "the configured prefix won" || return 0
    done_ok
}

t_naming_collision_with_a_stranger() {
    # The hazard the shorter prefix creates. `kamar-base` next to `kamar-checkout`
    # means `new checkout` aims straight at somebody else's clone — and the old
    # code would have said "entering the existing one" and started an agent in it.
    scenario "naming: a directory that is not our worktree is refused, not entered" || return 0
    local repo; repo="$(make_repo_as n4 kamar-base main develop)"
    local stranger="$TMP/n4/kamar-checkout"
    mkdir -p "$stranger"; echo "somebody else's work" > "$stranger/file.txt"
    local out err rc
    out="$(awt_run "$repo" new checkout develop 2>"$TMP/e")"; rc=$?
    err="$(cat "$TMP/e")"
    assert_eq 1 "$rc" "exit code" || return 0
    assert_contains "$err" "not a working directory of this repository" "says why" || return 0
    assert_contains "$err" "prefix =" "and how to settle it" || return 0
    assert_eq "" "$out" "no path handed back for the shell to enter" || return 0
    assert_eq "somebody else's work" "$(cat "$stranger/file.txt")" "left untouched" || return 0
    done_ok
}

# --------------------------------------------------------------------------
# CLEAN NO LONGER TRUSTS A DIRECTORY NAME
# --------------------------------------------------------------------------
t_clean_ignores_a_lookalike() {
    # With the prefix shortened to `kamar`, any hand-made worktree called
    # `kamar-<something>` passes a name test. Provenance is the only thing that
    # still distinguishes a session from somebody's own working directory.
    scenario "clean: a worktree this tool never made is left alone despite matching the name" || return 0
    local repo; repo="$(make_repo_as n5 kamar-base main develop)"
    local mine; mine="$(awt_run "$repo" new ours develop 2>/dev/null)"
    local theirs="$TMP/n5/kamar-theirs"
    git -C "$repo" worktree add -q -b their-branch "$theirs" origin/develop 2>/dev/null
    awt_run "$repo" clean >/dev/null 2>&1
    assert_no_dir "$mine" "our own untouched session was removed" || return 0
    assert_dir "$theirs" "the lookalike survived" || return 0
    done_ok
}

# --------------------------------------------------------------------------
# THE QUESTION `new` NOW ASKS
# --------------------------------------------------------------------------
t_new_asks_for_the_base() {
    scenario "new: asks which branch to cut from, and uses the answer" || return 0
    local repo; repo="$(make_repo_as n6 kamar-base dev stage prod)"
    local out dir
    # Answer 2. detect_bases orders by its own list, so assert against what the
    # tool itself detected rather than against a guess.
    dir="$( cd "$repo" && printf '2\n' | AGENT_WORKTREES_NO_HERDR=1 HOME="$FAKE_HOME" \
        HERDR_PANE_ID="" AWT_ASK=1 "$BASH_UNDER_TEST" "$AWT_SH" new asked 2>"$TMP/e" )"
    out="$(cat "$TMP/e")"
    assert_contains "$out" "Cut the session off what?" "the question was asked" || return 0
    assert_dir "$dir" "a session was created" || return 0
    assert_contains "$out" "off origin/" "and it says which base it used" || return 0
    done_ok
}

t_new_does_not_ask_when_told() {
    scenario "new: a base on the command line skips the question" || return 0
    local repo; repo="$(make_repo_as n7 kamar-base main develop)"
    awt_run "$repo" new told develop >/dev/null 2>"$TMP/e"
    assert_not_contains "$(cat "$TMP/e")" "Cut the session off what?" \
        "nothing to ask about" || return 0
    done_ok
}

t_new_eof_at_the_base_question_creates_nothing() {
    # THE `set -e` HOLE. errexit does not reach inside `$( )` — bash inherits it
    # there only under `shopt -s inherit_errexit`, which the 3.2 on macOS does
    # not have — and `cmd_new` runs inside `dir="$(cmd_new ...)"`. So a bare
    # `exit 1` in the base question was demoted to "returned non-zero", and the
    # tool printed "Nothing was created" and then created it.
    scenario "new: end of input at the base question creates nothing and says so" || return 0
    local repo; repo="$(make_repo_as n8 kamar-base main develop)"
    local rc
    ( cd "$repo" && with_timeout env AGENT_WORKTREES_NO_HERDR=1 HOME="$FAKE_HOME" \
        HERDR_PANE_ID="" AWT_ASK=1 "$BASH_UNDER_TEST" "$AWT_SH" new nothing \
        </dev/null >/dev/null 2>"$TMP/e" ); rc=$?
    [ "$rc" -eq 124 ] && { fail "hung waiting for input nobody was going to give"; return 0; }
    assert_eq 1 "$rc" "exit code" || return 0
    assert_contains "$(cat "$TMP/e")" "Nothing was created" "says nothing was created" || return 0
    assert_no_dir "$TMP/n8/kamar-nothing" "and means it" || return 0
    done_ok
}

t_hotfix_label_matches_what_is_made() {
    # The survey previewed `session/x` while cmd_new went on to create
    # `hotfix/x`. One function decides now, so a single-base repository gets a
    # plain session rather than a hotfix nobody chose.
    scenario "branch: a repository with one base makes a session, not a hotfix" || return 0
    local repo; repo="$(make_repo_as n9 kamar-base main)"
    local dir; dir="$(awt_run "$repo" new only 2>/dev/null)"
    assert_eq "session/only" "$(git -C "$dir" rev-parse --abbrev-ref HEAD)" \
        "no hotfix label where there was no choice" || return 0
    done_ok
}

t_nothing_written_to_the_real_home() {
    # RUNS LAST, and it is the one scenario whose subject is the suite itself.
    # It asserts the negative the other 55 cannot: that no scenario, anywhere,
    # wrote outside the sandbox because it forgot to redirect HOME.
    scenario "suite: no scenario wrote to the HOME it was not given" || return 0
    local leaked
    leaked="$(find "$UNTOUCHED_HOME" -mindepth 1 2>/dev/null | head -10)"
    if [ -n "$leaked" ]; then
        fail "something wrote to the real HOME: $(printf '%s' "$leaked" | tr '\n' ' ')"
        return 0
    fi
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

# THE TRAP THIS REPOSITORY HAS ALREADY PAID FOR ONCE.
# `producer | head -1` under `set -euo pipefail` returns 141 when the producer
# is still writing — after the value has been printed. `config` did exactly that,
# so `config agent || echo claude` could answer "claude\nclaude": a two-line
# agent name, which `command -v` cannot find, which silently downgrades a session
# to a plain shell with no agent in it.
#
# The fixture is absurd on purpose. Whether the pipe fills before `head` exits is
# the ONLY thing separating this from working by luck, so the test forces it
# rather than hoping for it — the same accident sat unnoticed in `default_base`
# through an entire release because a short branch list always fit.
t_config_first_line_has_no_pipe() {
    scenario "config: a value is one line even when the producer outfills the pipe" || return 0
    local repo; repo="$(make_repo c1 main develop)"
    local i=0
    : > "$repo/.agent-worktrees.conf"
    while [ "$i" -lt 5000 ]; do
        printf 'agent = claude\n' >> "$repo/.agent-worktrees.conf"
        i=$((i + 1))
    done
    mkdir -p "$TMP/bin"
    printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/claude"; chmod +x "$TMP/bin/claude"
    local out
    out="$( cd "$repo" && AGENT_WORKTREES_NO_HERDR=1 HOME="$FAKE_HOME" HERDR_PANE_ID="" \
        AWT_WRAPPER=2 PATH="$TMP/bin:$PATH" \
        "$BASH_UNDER_TEST" "$AWT_SH" new pipefull develop 2>/dev/null )"
    assert_eq 2 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "two lines: dir, agent" || return 0
    assert_eq "claude" "$(printf '%s\n' "$out" | sed -n 2p)" \
        "the agent survived the pipe, rather than becoming a plain shell" || return 0
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
        AGENT_WORKTREES_NO_HERDR=1 HOME="$FAKE_HOME" HERDR_PANE_ID="" AWT_WRAPPER=2 \
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
t_protocol_version_mismatch() {
    # THE FAILURE THIS WHOLE MECHANISM EXISTS FOR, and it is not hypothetical:
    # it happened on the author's own machine hours after the format changed,
    # having written the README section warning about exactly it. An out-of-date
    # function split the new reply on tabs, found none, handed `cd` all three
    # lines, and returned 1 with no explanation.
    scenario "protocol: an out-of-date wrapper is told so, before it is asked anything" || return 0
    local repo; repo="$(make_repo p1 main develop)"
    local out rc
    # </dev/null on purpose. Without it, removing the guard does not fail this
    # scenario — it HANGS it, waiting on a survey nobody is answering, and a
    # suite that hangs instead of failing is a suite people stop running.
    ( cd "$repo" && with_timeout env AGENT_WORKTREES_NO_HERDR=1 HOME="$FAKE_HOME" \
        HERDR_PANE_ID="" AWT_WRAPPER=1 "$BASH_UNDER_TEST" "$AWT_SH" start \
        </dev/null >/dev/null 2>"$TMP/e" ) ; rc=$?
    out="$(cat "$TMP/e")"
    [ "$rc" -eq 124 ] && { fail "hung instead of refusing — the guard is gone"; return 0; }
    assert_eq 1 "$rc" "exit code" || return 0
    assert_contains "$out" "out of date" "says what is wrong" || return 0
    assert_contains "$out" "install.sh" "says how to fix it" || return 0
    assert_not_contains "$out" "Session name" \
        "asked for a name before admitting it could not deliver the answer" || return 0
    assert_not_contains "$out" "Cut the session off what" "and did not ask for a base either" || return 0
    done_ok
}

t_protocol_version_absent() {
    scenario "protocol: run directly, with no wrapper at all, nothing is refused" || return 0
    local repo; repo="$(make_repo p2 main develop)"
    local out
    local dir
    dir="$(awt_run "$repo" new direct develop 2>"$TMP/e")"
    assert_not_contains "$(cat "$TMP/e")" "out of date" "a direct run is not a stale wrapper" || return 0
    assert_dir "$dir" "the session was created" || return 0
    done_ok
}

t_survey_eof() {
    # Found by a test HANGING rather than failing. `read` fails at end of input,
    # the old read_line turned that into an empty string, and ask_name rejected
    # the empty string and asked again — for ever. Anything running the survey
    # without a human hits it: a pipeline, a CI job, `awt < /dev/null`.
    scenario "survey: end of input stops with an explanation, it does not spin" || return 0
    local repo; repo="$(make_repo p3 main develop)"
    local out rc
    ( cd "$repo" && with_timeout env AGENT_WORKTREES_NO_HERDR=1 HOME="$FAKE_HOME" \
        HERDR_PANE_ID="" "$BASH_UNDER_TEST" "$AWT_SH" start \
        </dev/null >/dev/null 2>"$TMP/e" ) ; rc=$?
    out="$(cat "$TMP/e")"
    [ "$rc" -eq 124 ] && { fail "spun on end of input instead of stopping"; return 0; }
    assert_eq 1 "$rc" "exit code" || return 0
    assert_contains "$out" "No input" "says what happened" || return 0
    assert_contains "$out" "agent-worktrees new" "offers the non-interactive route" || return 0
    assert_eq 0 "$(find "$TMP/p3" -maxdepth 1 -name '*-session-*' 2>/dev/null | wc -l | tr -d ' ')" \
        "nothing was created" || return 0
    done_ok
}

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
    local session; session="$(awt_run "$repo" new theta develop 2>"$TMP/e")"
    local skey; skey="$(printf '%s' "$session" | tr '/_' '--')"
    [ -L "$FAKE_HOME/.claude/projects/$skey" ] || { fail "no symlink for the session"; return 0; }
    assert_eq "remembered" \
        "$(cat "$FAKE_HOME/.claude/projects/$skey/note.txt" 2>/dev/null)" \
        "the session sees the main project's memory" || return 0

    # ORDER, because it is the difference between a summary and a puzzle: the
    # memory line used to be printed by link_memory as it ran, which put an
    # indented detail ABOVE the heading it belongs under.
    local heading memory
    heading="$(grep -n 'ready\.' "$TMP/e" | head -1 | cut -d: -f1)"
    memory="$(grep -n 'memory:' "$TMP/e" | head -1 | cut -d: -f1)"
    if [ -z "$heading" ] || [ -z "$memory" ]; then
        fail "expected both a heading and a memory line"; return 0
    fi
    [ "$heading" -lt "$memory" ] || { fail "the memory line came before its heading"; return 0; }
    done_ok
}

t_no_herdr_flag() {
    scenario "herdr: AGENT_WORKTREES_NO_HERDR makes verify report it as absent" || return 0
    local repo; repo="$(make_repo r12 main develop)"
    assert_contains "$(awt_run "$repo" verify 2>&1)" "not in PATH" \
        "verify degrades instead of failing" || return 0
    done_ok
}

# --------------------------------------------------------------------------
# HERDR, WITHOUT A LIVE HERDR
# --------------------------------------------------------------------------
# Every herdr path was previously untested for a good reason: exercising it
# against a real server rearranges the panes of whoever is working right now.
# A fake on PATH removes the reason. It records its argv in call order and
# answers the two commands whose OUTPUT the tool actually parses, so
# `adopt_current_pane` and `herdr_forget` can be checked properly — including
# the ordering that matters (move the pane before closing the spawned one;
# closing first would take the workspace's only pane and the workspace with it).
fake_herdr() { # dir  [create-fails]
    local d="$1" fails="${2:-}"
    mkdir -p "$d/bin"
    cat > "$d/bin/herdr" <<HERDR
#!/bin/sh
printf '%s\n' "\$*" >> "$d/herdr.calls"
case "\$1 \$2" in
    "worktree create")
        [ -n "$fails" ] && exit 1
        # Real herdr CREATES the worktree; the tool only adds a fresh base and
        # shared memory on top. A fake that answered without creating anything
        # would be testing a herdr that does not exist.
        if [ -z "\$HERDR_FAKE_HOLLOW" ]; then
            _cwd=; _branch=; _base=; _path=
            while [ \$# -gt 0 ]; do
                case "\$1" in
                    --cwd) _cwd="\$2"; shift ;;
                    --branch) _branch="\$2"; shift ;;
                    --base) _base="\$2"; shift ;;
                    --path) _path="\$2"; shift ;;
                esac
                shift
            done
            git -C "\$_cwd" worktree add -b "\$_branch" "\$_path" "\$_base" >/dev/null 2>&1
        fi
        printf '%s' '{"result":{"workspace":{"workspace_id":"ws-1"},"root_pane":{"pane_id":"pane-spawned"}}}'
        ;;
    "workspace list")
        printf '%s' '{"result":{"workspaces":[{"workspace_id":"ws-1","worktree":{"checkout_path":"'"\$HERDR_FAKE_PATH"'"}}]}}'
        ;;
    "--version"*) printf 'herdr 0.0.0-fake\n' ;;
esac
exit 0
HERDR
    chmod +x "$d/bin/herdr"
    : > "$d/herdr.calls"
}

# Same as awt_run but WITH herdr enabled and the fake first on PATH.
#
# HERDR_PANE_ID is cleared everywhere in this suite. Whoever runs it is quite
# likely sitting in a herdr pane, which exports that variable — and inheriting it
# made the "no pane is touched" scenario pass or fail depending on which terminal
# the suite was started from. A test that consults the developer's environment is
# not a test.
awt_run_herdr() { # dir fakedir args...
    local d="$1" f="$2"; shift 2
    ( cd "$d" && HOME="$FAKE_HOME" PATH="$f/bin:$PATH" \
        HERDR_PANE_ID="" HERDR_FAKE_PATH="${HERDR_FAKE_PATH:-}" \
        "$BASH_UNDER_TEST" "$AWT_SH" "$@" )
}

t_herdr_creates() {
    scenario "herdr: worktree creation is handed over, with --no-focus" || return 0
    command -v jq >/dev/null 2>&1 || { dim "    (no jq here — skipped)"; SKIP=$((SKIP + 1)); return 0; }
    local repo; repo="$(make_repo h1 main develop)"
    local f="$TMP/fake-h1"; fake_herdr "$f"
    local out; out="$(awt_run_herdr "$repo" "$f" new iota develop 2>/dev/null)"
    local calls; calls="$(cat "$f/herdr.calls")"
    assert_contains "$calls" "worktree create" "herdr was asked to create it" || return 0
    assert_contains "$calls" "--no-focus" "creation never steals focus" || return 0
    assert_contains "$calls" "--base origin/develop" "the fresh remote base is passed on" || return 0
    assert_contains "$calls" "--branch session/iota" "the branch name is passed on" || return 0
    assert_dir "$out" "the worktree still exists (the tool made it, herdr is a fake)" || return 0
    done_ok
}

t_herdr_create_fails() {
    # The fallback that keeps a broken or absent herdr from costing you a session.
    scenario "herdr: a failed hand-over falls back to plain git" || return 0
    local repo; repo="$(make_repo h2 main develop)"
    local f="$TMP/fake-h2"; fake_herdr "$f" fails
    local out rc
    out="$(awt_run_herdr "$repo" "$f" new kappa develop 2>/dev/null)"; rc=$?
    assert_eq 0 "$rc" "exit code" || return 0
    assert_dir "$out" "the worktree was created anyway" || return 0
    assert_eq "session/kappa" "$(git -C "$out" rev-parse --abbrev-ref HEAD)" "branch" || return 0
    done_ok
}

t_herdr_adopts_pane() {
    # ONE SESSION, ONE WORKSPACE, ONE TAB. Order is the assertion: move first,
    # close second. And the rename must use the SESSION's name, not the
    # directory the human happened to be standing in.
    scenario "herdr: the current pane is moved into the workspace, then the spare is closed" || return 0
    command -v jq >/dev/null 2>&1 || { dim "    (no jq here — skipped)"; SKIP=$((SKIP + 1)); return 0; }
    local repo; repo="$(make_repo h3 main develop)"
    local f="$TMP/fake-h3"; fake_herdr "$f"
    ( cd "$repo" && HOME="$FAKE_HOME" PATH="$f/bin:$PATH" HERDR_PANE_ID="pane-human" \
        "$BASH_UNDER_TEST" "$AWT_SH" new lambda develop ) >/dev/null 2>&1
    local calls; calls="$(cat "$f/herdr.calls")"
    assert_contains "$calls" "pane move pane-human --new-tab --workspace ws-1 --no-focus" \
        "the human's pane is moved, in a new tab, without focus" || return 0
    assert_contains "$calls" "pane close pane-spawned" "the untouched spawned pane is closed" || return 0
    local move_line close_line
    move_line="$(grep -n "pane move" "$f/herdr.calls" | head -1 | cut -d: -f1)"
    close_line="$(grep -n "pane close" "$f/herdr.calls" | head -1 | cut -d: -f1)"
    [ "$move_line" -lt "$close_line" ] || { fail "closed before moving — that takes the workspace with it"; return 0; }
    assert_contains "$calls" "workspace rename ws-1 " "the workspace is renamed" || return 0
    # The fixture repository is called `work`, so its sessions are `work-<name>`.
    # The point of the assertion is unchanged: the workspace is named after the
    # session, not after whatever directory the human happened to be standing in.
    assert_contains "$(grep 'workspace rename' "$f/herdr.calls")" "work-lambda" \
        "renamed after the SESSION, not after the directory the human was in" || return 0
    done_ok
}

t_herdr_no_pane_id() {
    scenario "herdr: without HERDR_PANE_ID the session still works, minus the tidy-up" || return 0
    local repo; repo="$(make_repo h4 main develop)"
    local f="$TMP/fake-h4"; fake_herdr "$f"
    local out; out="$(awt_run_herdr "$repo" "$f" new mu develop 2>/dev/null)"
    assert_dir "$out" "session created" || return 0
    assert_not_contains "$(cat "$f/herdr.calls")" "pane move" "no pane is touched" || return 0
    done_ok
}

t_herdr_hollow_success() {
    # Found by the fake: if herdr reports success but creates nothing, the tool
    # used to announce a ready session and hand the wrapper a path to `cd` into
    # that was not there. Trusting the hand-over is right; trusting it blindly is
    # not, and the check costs one stat.
    scenario "herdr: a hand-over that reports success but creates nothing is caught" || return 0
    local repo; repo="$(make_repo h7 main develop)"
    local f="$TMP/fake-h7"; fake_herdr "$f"
    local out rc err
    out="$( cd "$repo" && HOME="$FAKE_HOME" PATH="$f/bin:$PATH" HERDR_PANE_ID="" HERDR_FAKE_HOLLOW=1 \
        "$BASH_UNDER_TEST" "$AWT_SH" new omicron develop 2>"$TMP/e" )"; rc=$?
    err="$(cat "$TMP/e")"
    assert_eq 1 "$rc" "exit code" || return 0
    assert_eq "" "$out" "no path is printed for a session that does not exist" || return 0
    assert_contains "$err" "reported success but created nothing" "explains what happened" || return 0
    done_ok
}

t_herdr_forget() {
    scenario "herdr: clean closes the workspace of every worktree it removes" || return 0
    command -v jq >/dev/null 2>&1 || { dim "    (no jq here — skipped)"; SKIP=$((SKIP + 1)); return 0; }
    local repo; repo="$(make_repo h5 main develop)"
    local f="$TMP/fake-h5"; fake_herdr "$f"
    local session; session="$(awt_run "$repo" new nu develop 2>/dev/null)"
    : > "$f/herdr.calls"
    ( cd "$repo" && HOME="$FAKE_HOME" PATH="$f/bin:$PATH" HERDR_PANE_ID="" HERDR_FAKE_PATH="$session" \
        "$BASH_UNDER_TEST" "$AWT_SH" clean ) >/dev/null 2>&1
    assert_no_dir "$session" "the worktree is gone" || return 0
    assert_contains "$(cat "$f/herdr.calls")" "workspace close ws-1" \
        "and its registry entry with it" || return 0
    done_ok
}

t_herdr_forget_no_match() {
    scenario "herdr: a worktree herdr never knew about is removed without complaint" || return 0
    local repo; repo="$(make_repo h6 main develop)"
    local f="$TMP/fake-h6"; fake_herdr "$f"
    local session; session="$(awt_run "$repo" new xi develop 2>/dev/null)"
    : > "$f/herdr.calls"
    local rc
    ( cd "$repo" && HOME="$FAKE_HOME" PATH="$f/bin:$PATH" HERDR_PANE_ID="" HERDR_FAKE_PATH="/nowhere/at/all" \
        "$BASH_UNDER_TEST" "$AWT_SH" clean ) >/dev/null 2>&1; rc=$?
    assert_eq 0 "$rc" "clean still succeeds" || return 0
    assert_no_dir "$session" "the worktree is gone" || return 0
    assert_not_contains "$(cat "$f/herdr.calls")" "workspace close" "nothing was closed" || return 0
    done_ok
}

# --------------------------------------------------------------------------
# REHEARSING, WHERE, AND CLEAN AGAINST A MOVING BASE
# --------------------------------------------------------------------------
# `advance_base` puts a real commit on origin/<base> so "behind" is genuine
# rather than simulated — the counts come from `git rev-list`, which a fixture
# faking the ref would answer wrongly.
advance_base() { # repo base file content
    local repo="$1" base="$2" file="$3" content="$4"
    local tmp="$TMP/advance.$$"
    git clone -q --branch "$base" "$(git -C "$repo" remote get-url origin)" "$tmp"
    (
        cd "$tmp" && git config user.email t@example.com && git config user.name Test \
            && git config commit.gpgsign false \
            && printf '%s\n' "$content" > "$file" && git add "$file" \
            && git commit -qm "base moves" && git push -q origin "$base"
    )
    rm -rf "$tmp"
}

t_rehearse_clean() {
    scenario "rehearse: behind but mergeable says so and changes nothing" || return 0
    local repo; repo="$(make_repo r13 main develop)"
    local session; session="$(awt_run "$repo" new rho develop 2>/dev/null)"
    advance_base "$repo" develop "theirs.txt" "from the base"
    echo "mine" > "$session/mine.txt"
    local out rc
    out="$(awt_run "$session" rehearse 2>&1)"; rc=$?
    assert_eq 0 "$rc" "exit code" || return 0
    assert_contains "$out" "commits to pull, NO conflict" "reports a clean merge" || return 0
    [ -f "$session/theirs.txt" ] && { fail "the rehearsal actually merged — it must not touch the tree"; return 0; }
    assert_eq "mine" "$(cat "$session/mine.txt")" "uncommitted work untouched" || return 0
    done_ok
}

t_rehearse_conflict() {
    # The case the whole command exists for, and the one never exercised before:
    # the rehearsal must SEE the conflict while leaving the directory alone.
    scenario "rehearse: a real conflict is reported and the tree is left alone" || return 0
    local repo; repo="$(make_repo r14 main develop)"
    local session; session="$(awt_run "$repo" new sigma develop 2>/dev/null)"
    advance_base "$repo" develop "README.md" "the base rewrote this line"
    (
        cd "$session" && git config user.email t@example.com && git config user.name Test \
            && git config commit.gpgsign false \
            && printf '%s\n' "the session rewrote this line" > README.md \
            && git add README.md && git commit -qm "mine"
    )
    local out rc
    out="$(awt_run "$session" rehearse 2>&1)"; rc=$?
    assert_eq 1 "$rc" "a conflict is a non-zero exit" || return 0
    assert_contains "$out" "CONFLICT" "says so" || return 0
    assert_contains "$out" "README.md" "names the file needing a decision" || return 0
    assert_eq "the session rewrote this line" "$(cat "$session/README.md")" \
        "the working tree was NOT touched" || return 0
    assert_eq "" "$(git -C "$session" status --porcelain)" "no half-merged state left behind" || return 0
    done_ok
}

t_where_counts() {
    scenario "where: counts commits of your own and how far behind the base is" || return 0
    local repo; repo="$(make_repo r15 main develop)"
    local session; session="$(awt_run "$repo" new tau develop 2>/dev/null)"
    (
        cd "$session" && git config user.email t@example.com && git config user.name Test \
            && git config commit.gpgsign false \
            && echo one > a.txt && git add a.txt && git commit -qm one \
            && echo two > b.txt && git add b.txt && git commit -qm two
    )
    advance_base "$repo" develop "theirs.txt" "moved"
    ( cd "$session" && git fetch -q origin )
    local out
    out="$(awt_run "$session" where 2>&1)"
    assert_contains "$out" "commits of your own: 2" "counts your commits against the BASE" || return 0
    assert_contains "$out" "1 commits behind" "counts how far behind" || return 0
    assert_contains "$out" "session/tau" "names the branch" || return 0
    done_ok
}

t_clean_keeps_committed_after_base_moves() {
    # `base_of` exists precisely so this cannot go wrong: counting against a
    # fixed branch instead of the recorded base would let a session holding real
    # work look empty once the base moved on.
    scenario "clean: a session with commits survives the base moving underneath it" || return 0
    local repo; repo="$(make_repo r16 main develop)"
    local session; session="$(awt_run "$repo" new upsilon develop 2>/dev/null)"
    (
        cd "$session" && git config user.email t@example.com && git config user.name Test \
            && git config commit.gpgsign false \
            && echo work > work.txt && git add work.txt && git commit -qm "real work"
    )
    advance_base "$repo" develop "theirs.txt" "moved"
    ( cd "$repo" && git fetch -q origin )
    awt_run "$repo" clean >/dev/null 2>&1
    assert_dir "$session" "the session with real work is still there" || return 0
    done_ok
}

# --------------------------------------------------------------------------
# THE INSTALLER
# --------------------------------------------------------------------------
# Never against the real HOME: this writes symlinks and reads shell rc files.
install_into() { # home  -> stdout of install.sh
    local h="$1"
    mkdir -p "$h"
    ( HOME="$h" ZDOTDIR="$h" "$BASH_UNDER_TEST" "$ROOT/install.sh" 2>&1 )
}

t_install_symlinks() {
    scenario "install: symlinks both the tool and the shell function" || return 0
    local h="$TMP/home-install"; mkdir -p "$h"; : > "$h/.zshrc"
    local out; out="$(install_into "$h")"
    [ -L "$h/.local/bin/agent-worktrees" ] || { fail "no symlink for the tool"; return 0; }
    [ -L "$h/.local/share/agent-worktrees/awt.sh" ] || { fail "no symlink for the function"; return 0; }
    assert_eq "$AWT_SH" "$(readlink "$h/.local/bin/agent-worktrees")" "tool points at the checkout" || return 0
    assert_eq "$FUNC_SH" "$(readlink "$h/.local/share/agent-worktrees/awt.sh")" \
        "function points at the checkout — a copy could drift" || return 0
    assert_contains "$out" "agent-worktrees/awt.sh" "prints the line to add" || return 0
    done_ok
}

t_install_idempotent() {
    scenario "install: run twice, and the second run notices the line is there" || return 0
    local h="$TMP/home-twice"; mkdir -p "$h"
    printf '%s
' '[ -f "$HOME/.local/share/agent-worktrees/awt.sh" ] && . "$HOME/.local/share/agent-worktrees/awt.sh"' > "$h/.zshrc"
    local out; out="$(install_into "$h")"
    assert_contains "$out" "already sourced" "says so instead of printing the block again" || return 0
    done_ok
}

t_install_warns_about_pasted_copy() {
    # The exact situation every existing user is in: a hand-pasted awt() from
    # before there was a file to source. It cannot follow a protocol change, so
    # leaving it in place is how somebody keeps running the broken wrapper.
    scenario "install: warns about an older pasted-in awt() function" || return 0
    local h="$TMP/home-stale"; mkdir -p "$h"
    printf 'awt() {
  local cli="$HOME/.local/bin/agent-worktrees"
}
' > "$h/.zshrc"
    local out; out="$(install_into "$h")"
    assert_contains "$out" "DELETE IT" "tells you to remove it" || return 0
    assert_contains "$out" "cannot follow changes to the protocol" "and why" || return 0
    done_ok
}

t_install_reports_herdr_without_demanding_it() {
    scenario "install: mentions a missing herdr once, and asks for nothing" || return 0
    local h="$TMP/home-herdr"; mkdir -p "$h"; : > "$h/.zshrc"
    local out
    out="$( PATH="/usr/bin:/bin" HOME="$h" ZDOTDIR="$h" "$BASH_UNDER_TEST" "$ROOT/install.sh" 2>&1 )"
    assert_contains "$out" "nothing here needs it" "reports it as optional" || return 0
    assert_not_contains "$out" "[y/N]" "no prompt" || return 0
    assert_not_contains "$out" "Install herdr?" "no prompt" || return 0
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

# ==========================================================================
# THE HOME NOBODY IS SUPPOSED TO REACH
# ==========================================================================
# Every scenario passes HOME="$FAKE_HOME" to the tool, because the tool writes
# symlinks into ~/.claude/projects and a suite that writes into somebody's real
# one is a suite people are right to stop running.
#
# "Every scenario" is the part worth checking rather than believing. A single
# invocation that forgets the variable inherits the real HOME and writes there
# for as long as nobody notices — and it would not fail a single assertion,
# because the scenarios test WHAT the tool does, never WHERE.
#
# So the suite gives ITSELF a throwaway HOME too. Anything that overrides it
# lands in FAKE_HOME as intended; anything that forgets lands here, in a
# directory asserted to be empty at the end of the run.
#
# WHAT IT ACTUALLY CATCHES, measured by breaking each path on purpose rather than
# assumed — because a guard nobody has seen go red is the thing it is guarding
# against:
#
#   install.sh with HOME dropped   -> CAUGHT. This is the destructive one: it
#                                     symlinks into ~/.local/bin and appends a
#                                     line to the real ~/.zshrc.
#   the tool with HOME dropped     -> NOT caught here, and cannot be. link_memory
#                                     writes only when ~/.claude/projects/<key of
#                                     the main repo> already exists, and in a
#                                     throwaway home it never does — so a
#                                     forgotten HOME produces a MISSING symlink,
#                                     not a stray one. `t_memory_symlink` fails on
#                                     exactly that, which is how it was confirmed.
#
# Both halves are covered; only one of them is covered from here. Anything added
# later that writes under $HOME without that precondition — a cache, a log, a
# state file — falls to this scenario, which is the case it exists for.
#
# Suggested by the brain-mcp session, which found exactly this in its own suite:
# a hook with a hard-coded state directory had been writing real records into the
# user's incident log for a year, and 37 of the 102 entries turned out to be one
# line of a fixture. Their tests passed throughout, because they checked what the
# hook detected and never where it wrote.
UNTOUCHED_HOME="$TMP/home-nobody-should-write-to"
mkdir -p "$UNTOUCHED_HOME"
export HOME="$UNTOUCHED_HOME"

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
t_outside_repo_points_at_one
t_unknown_command
t_unknown_command_typo
t_unknown_flag_gets_the_list
t_help_is_asked_for
t_new_enters_the_session
t_new_without_wrapper_still_prints_a_path
t_new_stale_wrapper_refused
t_naming_strips_the_base_suffix
t_naming_keeps_a_name_with_nothing_redundant
t_naming_config_overrides
t_naming_collision_with_a_stranger
t_clean_ignores_a_lookalike
t_new_asks_for_the_base
t_new_does_not_ask_when_told
t_new_eof_at_the_base_question_creates_nothing
t_hotfix_label_matches_what_is_made
t_config
t_config_first_line_has_no_pipe
t_protocol
t_protocol_version_mismatch
t_protocol_version_absent
t_survey_eof
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
t_herdr_creates
t_herdr_create_fails
t_herdr_adopts_pane
t_herdr_no_pane_id
t_herdr_hollow_success
t_herdr_forget
t_herdr_forget_no_match
t_rehearse_clean
t_rehearse_conflict
t_where_counts
t_clean_keeps_committed_after_base_moves
t_install_symlinks
t_install_idempotent
t_install_warns_about_pasted_copy
t_install_reports_herdr_without_demanding_it
t_nothing_written_to_the_real_home

printf '\n'
if [ "$FAIL" -eq 0 ]; then
    green "$PASS passed, $SKIP skipped, 0 failed"
    exit 0
else
    red "$PASS passed, $SKIP skipped, $FAIL FAILED"
    printf '%s\n' "$FAILED_NAMES"
    exit 1
fi
