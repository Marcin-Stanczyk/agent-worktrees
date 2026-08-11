#!/usr/bin/env bash
#
# agent-worktrees — one agent, one working directory.
#
# WHY THIS EXISTS
# ===============
# Two AI agents were working in the SAME checkout of the same repository. One
# agent's commit swallowed the other's uncommitted files, and a rebase rewrote
# hashes that had already been pushed. A whole feature survived only because
# somebody noticed in time.
#
# That was nobody's carelessness. With a single checkout, `git add` HAS NO WAY
# to tell my files from yours — it sees one index.
#
# Git already solves this: `git worktree`. One repository (shared objects and
# refs), MANY independent working directories, each with its own checkout and
# its own index. Two sessions physically cannot overwrite each other's files,
# and git REFUSES to check out the same branch in two worktrees at once — a
# built-in lock, not a convention you have to remember.
#
# WHAT WORKTREES DO NOT SOLVE
# ===========================
# Objects and refs are shared, so `rebase`, `commit --amend` and `push --force`
# on a PUSHED branch still destroy the other person's work. A worktree protects
# the working directory, not history.
#
# USAGE
#   agent-worktrees                     # SURVEY: base, name, agent (default)
#   agent-worktrees new <name> [base]   # no questions asked
#   agent-worktrees list                # what is taken and by whom
#   agent-worktrees where               # where am I, off what, how far behind
#   agent-worktrees rehearse            # would pulling the base conflict?
#   agent-worktrees clean               # remove untouched session worktrees
#   agent-worktrees verify              # is the isolation actually working?
#
# Shell integration and installation: see README.md

set -euo pipefail

# ---------------------------------------------------------------------------
# THE PROTOCOL HAS A VERSION, AND THAT IS NOT CEREMONY
# ---------------------------------------------------------------------------
# The shell function and this script talk to each other. When the format changed
# — three tab-separated fields became one field per line — every shell still
# holding the older function silently stopped working: it split on tabs, found
# none, and handed `cd` the whole three-line reply. `awt` did nothing and
# returned 1, with no clue as to why.
#
# That happened on the author's own machine, hours after the change, having
# written the README section warning about exactly it.
#
# The installer now sources one file instead of printing a copy to paste, so
# this cannot recur for anyone who reinstalls. It says nothing to anyone who
# does not. So the version travels with the request: the wrapper announces which
# protocol it speaks, and a mismatch becomes a sentence instead of a silence.
AWT_PROTOCOL=2

# ---------------------------------------------------------------------------
# THIS TOOL BELONGS TO NO PARTICULAR PROJECT
# ---------------------------------------------------------------------------
# The repository is resolved from THE DIRECTORY YOU ARE STANDING IN, not from
# where this script lives. It used to be the other way round, and the result was
# that running it inside project B created a session for project A — because
# that is where the file happened to sit.
#
# `--git-common-dir` rather than `--show-toplevel`: inside a worktree the former
# points at the MAIN repository, the latter at the current checkout. We want the
# main one, otherwise a session started from inside a session would nest.
MAIN="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -z "$MAIN" ]]; then
    printf '\033[0;31m%s\033[0m\n' "Not inside a git repository." >&2

    # SAY WHERE ONE IS, not merely that this is not it. The directory you keep a
    # project in is usually the PARENT of its checkouts — `kamar/` holding
    # `kamar-base` and `kamar-checkout` — so standing one level too high is the
    # ordinary mistake, not an exotic one. The old message sent you off to `ls`
    # and guess; this one prints the `cd` you were about to type.
    #
    # An explicit `if` rather than `[[ ... ]] && found=...`: under `set -e` an
    # AND-list whose test fails is a failed command, and the first directory
    # without a .git would end the script in silence.
    found=""
    for d in */; do
        if [[ -e "${d%/}/.git" ]]; then
            found="${found}  cd ${d%/}
"
        fi
    done
    if [[ -n "$found" ]]; then
        printf '%s\n' "Repositories directly below here:" >&2
        printf '%s' "$found" >&2
    else
        printf '%s\n' "Change into the project you want a session for and try again." >&2
    fi
    exit 1
fi
MAIN="$(cd "$MAIN" && pwd)"      # may be a relative path
MAIN="$(dirname "$MAIN")"        # .../repo/.git -> .../repo
PARENT="$(dirname "$MAIN")"
PREFIX="$(basename "$MAIN")-session"

# CHANNEL DISCIPLINE, and it is load-bearing.
# Everything a HUMAN reads goes to stderr. stdout carries one thing only: the
# session path, and the tab-separated protocol line the shell function parses.
# When these mixed, the wrapper did `cd` on a coloured banner glued to the path
# and failed with "no such file or directory: <escape codes>New working session…".
# ---------------------------------------------------------------------------
# THE FIRST LINE OF SOMETHING, WITHOUT A PIPE
# ---------------------------------------------------------------------------
# `head -1` is the obvious way and it is the one that cost this tool a release.
# Under `set -euo pipefail` head closes the pipe after the first line, the
# producer is killed by SIGPIPE, and pipefail turns 141 into the status of the
# whole pipeline — so the pipeline FAILS after having printed the right answer.
# Whether it happens at all depends on whether the producer's output fits in the
# pipe buffer, which is why it looks like it works until one day it does not.
#
# A parameter expansion has no pipe, no second process and no race.
first_line() { printf '%s\n' "${1%%$'\n'*}"; }

color() { printf '\033[%sm%s\033[0m\n' "$1" "$2" >&2; }
info()  { color '0;36' "$1"; }
ok()    { color '0;32' "$1"; }
warn()  { color '0;33' "$1"; }
err()   { color '0;31' "$1"; }

# ---------------------------------------------------------------------------
# CONFIGURATION — a file in the repository, detection as the fallback
# ---------------------------------------------------------------------------
# `.agent-worktrees.conf` lives in the repository root. Parsed STRICTLY, never
# sourced: reading configuration with `source` means a file in the project
# directory gets to execute arbitrary code, which is a risk not worth taking for
# a file this simple.
#
#   bases      = develop, main
#   release    = main
#   agent      = claude
#   agent_args = --add-dir ../sibling-repo
#
# NOTE THE ABSENCE OF `| head -1`, AND IT IS NOT PEDANTRY. `producer | head -1`
# under `set -euo pipefail` is the bug that made `new <name>` fail in EVERY
# repository, in silence: head closes the pipe, the producer dies of SIGPIPE,
# pipefail reports 141 for the whole pipeline. Here the value has ALREADY been
# printed by then, so `config agent || echo claude` returned "claude\nclaude" —
# a two-line agent name that `command -v` cannot find. Cutting the first line
# with a parameter expansion involves no pipe and therefore no race.
config() {
    local file="$MAIN/.agent-worktrees.conf" key="$1" found
    [[ -f "$file" ]] || return 1
    found="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$file" \
             | sed 's/[[:space:]]*$//')"
    found="$(first_line "$found")"
    [[ -n "$found" ]] || return 1
    printf '%s\n' "$found"
}

# Branch names differ wildly between projects, so nothing is hard-coded. If the
# config does not say, we look for the conventional names and keep the ones that
# actually exist on the remote — offering a base that isn't there would only fail
# later, after the user has already typed a name.
detect_bases() {
    local configured b out=()
    if configured="$(config bases 2>/dev/null)"; then
        IFS=',' read -ra out <<< "$configured"
        for b in "${out[@]}"; do
            b="$(echo "$b" | xargs)"
            [[ -n "$b" ]] || continue
            # CONFIGURED NAMES ARE CHECKED TOO, and that is the whole point.
            # An earlier version trusted the config and only verified the
            # auto-detected names. A typo — or a project that renamed its
            # branches — then failed with "No such base" AFTER the user had
            # already picked a base, typed a name and chosen an agent. The
            # config is written by hand, so it is exactly where a wrong name
            # comes from.
            if git -C "$MAIN" rev-parse --verify --quiet "origin/$b" >/dev/null; then
                printf '%s\n' "$b"
            else
                warn "  .agent-worktrees.conf lists '$b', but origin/$b does not exist — skipping"
            fi
        done
        return 0
    fi
    for b in develop dev staging stage main master production prod; do
        git -C "$MAIN" rev-parse --verify --quiet "origin/$b" >/dev/null && printf '%s\n' "$b"
    done
}

# The release branch is the one a hotfix targets. It gets a different branch
# prefix and an extra warning, because a fix merged ONLY there is silently
# reverted by the next release — the hardest kind of regression to spot, since
# nobody broke anything.
release_branch() {
    local configured
    if configured="$(config release 2>/dev/null)"; then
        # Same reason as above: a release branch that does not exist would send
        # a hotfix off nothing at all.
        if git -C "$MAIN" rev-parse --verify --quiet "origin/$configured" >/dev/null; then
            printf '%s\n' "$configured"; return 0
        fi
        warn "  .agent-worktrees.conf sets release = $configured, but origin/$configured does not exist"
    fi
    local b
    for b in production prod main master; do
        git -C "$MAIN" rev-parse --verify --quiet "origin/$b" >/dev/null && { printf '%s\n' "$b"; return 0; }
    done
    return 1
}

# `detect_bases | head -1` is what this used to be, and it never once worked.
# `head` closes the pipe after the first line, the producer is killed by SIGPIPE,
# `set -o pipefail` reports 141 for the whole pipeline and `set -e` ends the
# script — with no message, no exit code anybody sees, and no worktree. Only the
# non-interactive path was affected, because the survey reads the same function
# through a process substitution where the status is discarded, so the bug sat
# there in plain sight while the tool "worked".
#
# So nothing is consumed half-way: collect first, then cut.
default_base() {
    local all
    all="$(detect_bases)" || true
    first_line "$all"
}

# EVERY base is a remote ref, so a repository without `origin` can answer none of
# the questions this tool asks. Without this check it failed anyway, but silently:
# `new` died on the fetch with an empty stderr, and the survey blamed the branches
# ("no usable base found on origin") in a repository that has no origin at all.
require_origin() {
    git -C "$MAIN" remote get-url origin >/dev/null 2>&1 && return 0
    err "This repository has no remote called 'origin'."
    {
        printf '%s\n' "Sessions are always cut from a remote branch, so there has to be one."
        local remotes; remotes="$(git -C "$MAIN" remote 2>/dev/null || true)"
        if [[ -n "$remotes" ]]; then
            printf '%s\n' "Remotes this repository does have:"
            printf '%s\n' "$remotes" | sed 's/^/  /'
            printf '%s\n' "Rename one of them:  git remote rename <name> origin"
        else
            printf '%s\n' "It has no remotes at all:  git remote add origin <url>"
        fi
    } >&2
    exit 1
}

# ---------------------------------------------------------------------------
# THE BASE A SESSION WAS CUT FROM
# ---------------------------------------------------------------------------
# From the moment a session exists, EVERY question of "how many commits are mine"
# and "am I behind" only makes sense against THAT base. Counting against a fixed
# branch instead produces numbers that are wrong in the worst direction: commits
# the release branch has but the development branch does not would count as
# "mine", so a worktree ready to be removed would linger — or, after a merge, a
# session holding real work would report zero and qualify for deletion.
#
# Stored in the SHARED repository config rather than the worktree config, so it
# survives the directory being removed and is visible from any other worktree.
remember_base() {
    git -C "$MAIN" config "branch.$1.awtBase" "$2"
}

base_of() {
    local branch="$1" stored upstream

    stored="$(git -C "$MAIN" config --get "branch.$branch.awtBase" 2>/dev/null || true)"
    if [[ -n "$stored" ]] && git -C "$MAIN" rev-parse --verify --quiet "$stored" >/dev/null; then
        echo "$stored"; return 0
    fi

    # Sessions created before this key existed do not have it. The base can still
    # be recovered from tracking, because `worktree add -b <branch> <base>` sets it.
    #
    # One condition is essential here: after `push -u` the upstream stops pointing
    # at the base and starts pointing at THE REMOTE COPY OF THE SAME BRANCH.
    # Without that exception a session would report zero commits behind and zero
    # of its own from its first push onward — looking untouched exactly when it
    # holds the most work.
    #
    # Verifying the ref EXISTS is mandatory, not defensive:
    # `rev-parse --symbolic-full-name` does NOT fail on an unresolvable name, it
    # echoes the input back (a literal "branch@{upstream}"). That garbage would
    # pass through as a base, `rev-list` would choke on it, and `|| echo 0` would
    # turn the failure into "zero commits of its own" — so a session with real
    # work would look untouched and be deleted.
    upstream="$(git -C "$MAIN" rev-parse --abbrev-ref --symbolic-full-name "$branch@{upstream}" 2>/dev/null || true)"
    if [[ -n "$upstream" && "$upstream" != "origin/$branch" ]] \
       && git -C "$MAIN" rev-parse --verify --quiet "$upstream" >/dev/null; then
        echo "$upstream"; return 0
    fi

    echo "origin/$(default_base)"
}

# ---------------------------------------------------------------------------
# THE SURVEY — one word, the rest is questions
# ---------------------------------------------------------------------------
# A menu in plain bash, no `gum`, `fzf` or `whiptail`, so that starting a session
# never requires installing anything. Questions go to stderr because stdout
# carries the result (the path) that the shell function reads.

# EOF IS AN ANSWER, AND IT USED TO BE AN INFINITE LOOP.
# `read` fails at end of input, the old version turned that into an empty string,
# and `ask_name` rejected the empty string and asked again — for ever, printing
# its complaint as fast as the terminal would take it. Reached by anything that
# runs the survey without a human on the other end: `awt < /dev/null`, a
# pipeline, a CI job, or a test that removes the guard which used to exit first.
# Found by a test hanging rather than failing, which is its own kind of warning.
read_line() {
    local l
    if ! read -r l; then
        printf '%s' "$l"
        return 1
    fi
    printf '%s' "$l"
}

# Callers all want the same thing on EOF: stop, say why, change nothing.
no_more_input() {
    err "No input — the survey cannot be answered."
    printf '%s\n' "Nothing was created. For a non-interactive session use:" >&2
    printf '%s\n' "  agent-worktrees new <name> [base]" >&2
    exit 1
}

choose() {
    local question="$1"; shift
    local options=("$@") i pick
    {
        printf '\n\033[0;36m%s\033[0m\n' "$question"
        for i in "${!options[@]}"; do printf '   %d) %s\n' "$((i + 1))" "${options[$i]}"; done
    } >&2
    while true; do
        printf '   choice [1]: ' >&2
        pick="$(read_line)" || no_more_input
        pick="${pick:-1}"
        if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#options[@]}" ]; then
            printf '%s\n' "${options[$((pick - 1))]}"; return 0
        fi
        printf '   \033[0;31mno such option\033[0m\n' >&2
    done
}

ask_name() {
    local name
    while true; do
        printf '\n\033[0;36mSession name\033[0m (directory, branch and window all get it)\n' >&2
        printf '   name: ' >&2
        name="$(read_line)" || no_more_input
        # Rejecting and asking again beats silently rewriting what somebody
        # typed. `is_session_name` holds the rule itself.
        if is_session_name "$name"; then
            printf '%s\n' "$name"; return 0
        fi
        printf '   \033[0;31mlowercase letters, digits and dashes, 2-39 characters\033[0m\n' >&2
    done
}

available_agents() {
    local a
    for a in claude gemini copilot codex aider; do
        command -v "$a" >/dev/null 2>&1 && printf '%s\n' "$a"
    done
    printf 'plain shell\n'
}

# BEFORE anything is created, not after. Doing the work and only then admitting
# the answer cannot be delivered is the rudest possible ordering, and it is the
# one the code had. Called by every command that replies through the wrapper —
# which, since `new` also enters the session, is now two of them.
require_current_wrapper() {
    [[ -n "${AWT_WRAPPER:-}" && "$AWT_WRAPPER" != "$AWT_PROTOCOL" ]] || return 0
    err "Your shell function is out of date and would mishandle the reply."
    {
        printf '%s\n' "It speaks protocol ${AWT_WRAPPER}; this tool speaks ${AWT_PROTOCOL}."
        printf '%s\n' "Almost certainly a copy of awt() pasted into your shell config before"
        printf '%s\n' "there was a file to source. Fix it once:"
        printf '%s\n' ""
        printf '%s\n' "  1. run ./install.sh in the agent-worktrees checkout"
        printf '%s\n' "  2. delete the awt() function from your shell config"
        printf '%s\n' "  3. add the single line install.sh prints, then open a new shell"
        printf '%s\n' ""
        printf '%s\n' "Everything else keeps working meanwhile: agent-worktrees new <name>"
        printf '%s\n' "runs without the function and prints the path for you to cd into."
    } >&2
    exit 1
}

# A slug: no spaces, no characters that surprise you in a branch name, a
# directory name or a `cd`. One definition, because the survey validates what
# you type and the dispatcher uses the same rule to tell a mistyped command
# from a session name — and two copies of a regex drift.
is_session_name() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9-]{1,38}$ ]]
}

# WHICH AGENT, WITHOUT ASKING. The survey asks; `new` promises not to, so it
# takes the configured agent and falls back to the shell rather than failing at
# the very end — a session that exists is worth having even if the agent is not
# installed.
session_agent() {
    local preferred
    preferred="$(config agent 2>/dev/null || echo claude)"
    if command -v "$preferred" >/dev/null 2>&1; then
        printf '%s\n' "$preferred"
        return 0
    fi
    warn "Agent \"$preferred\" is not in PATH — leaving you in a plain shell."
    printf '%s\n' "plain shell"
}

cmd_start() {
    local base name agent preferred release

    require_current_wrapper
    require_origin

    info "New working session — repository: $(basename "$MAIN")"

    local bases=() b labels=()
    while IFS= read -r b; do bases+=("$b"); done < <(detect_bases)
    if [ "${#bases[@]}" -eq 0 ]; then
        err "No usable base branch found on origin."
        printf '%s\n' "Branches that DO exist on origin:" >&2
        git -C "$MAIN" branch -r --format='%(refname:lstrip=3)' 2>/dev/null \
            | grep -v '^HEAD' | sed 's/^/  /' >&2
        printf '%s\n' "Set one of them in .agent-worktrees.conf, e.g.:  bases = dev, prod" >&2
        exit 1
    fi

    release="$(release_branch 2>/dev/null || true)"
    for b in "${bases[@]}"; do
        if [[ -n "$release" && "$b" == "$release" && "${#bases[@]}" -gt 1 ]]; then
            labels+=("$b — HOTFIX, goes straight to release")
        else
            labels+=("$b")
        fi
    done

    if [ "${#bases[@]}" -eq 1 ]; then
        base="${bases[0]}"
        info "  base: $base (the only one available)"
    else
        base="$(choose "Cut the session off what?" "${labels[@]}")"
        base="${base%% *}"
    fi

    name="$(ask_name)"

    preferred="$(config agent 2>/dev/null || echo claude)"
    # Two passes rather than prepending in place: expanding an EMPTY array under
    # `set -u` breaks on bash 3.2, which is what macOS ships in /bin/bash.
    local all=() agents=() a
    while IFS= read -r a; do all+=("$a"); done < <(available_agents)
    for a in "${all[@]}"; do [[ "$a" == "$preferred" ]] && agents+=("$a"); done
    for a in "${all[@]}"; do [[ "$a" == "$preferred" ]] || agents+=("$a"); done
    agent="$(choose "Which agent should start?" "${agents[@]}")"

    local is_hotfix="no"
    [[ -n "$release" && "$base" == "$release" && "${#bases[@]}" -gt 1 ]] && is_hotfix="yes"

    {
        printf '\n\033[0;33m%s\033[0m\n' "About to create:"
        printf '   branch:    %s\n' "$([ "$is_hotfix" = yes ] && echo "hotfix/$name" || echo "session/$name")"
        printf '   base:      origin/%s\n' "$base"
        printf '   directory: %s\n' "$PARENT/$PREFIX-$name"
        printf '   agent:     %s\n' "$agent"
        printf '   Enter to confirm, anything else to abort: '
    } >&2
    # EOF here is NOT an error: a bare Enter and a closed stdin both mean "no
    # objection", and the confirmation defaults to proceeding. Aborting on EOF
    # would make `yes "" | awt` behave differently from a human pressing Enter.
    local confirm; confirm="$(read_line)" || true
    if [[ -n "$confirm" ]]; then
        warn "Aborted — nothing was created."
        exit 0
    fi

    local dir; dir="$(cmd_new "$name" "$base")"

    # A process cannot change its parent shell's directory — that is a property of
    # processes, not a shortcoming here. When a shell function calls us
    # (AWT_WRAPPER=1) we hand it the path and the agent and let it do the `cd`.
    # Run directly, we change directory ourselves and replace the process.
    if [[ -n "${AWT_WRAPPER:-}" ]]; then
        # ONE FIELD PER LINE: directory, agent, then one extra argument per line.
        #
        # It used to be three tab-separated fields with the arguments packed into
        # the last one, which left the splitting to the shell function — and the
        # two shells this has to run in disagree about that. Bash splits an
        # unquoted expansion, zsh does not; the documented `${=args}` that fixes
        # zsh is a syntax error in bash. Either way an argument containing a
        # space was torn in half.
        #
        # Splitting here instead settles it: the script already knows where the
        # argument boundaries are, so it says so, and both shells only have to
        # read lines. Word-split on purpose below — `agent_args` is a list of
        # flags, not one string.
        local extra; extra="$(config agent_args 2>/dev/null || true)"
        # shellcheck disable=SC2086
        printf '%s\n' "$dir" "$agent" $extra
        return 0
    fi
    cd "$dir" || exit 1
    [[ "$agent" == "plain shell" ]] && exec "${SHELL:-/bin/bash}"

    # Extra arguments for the agent, e.g. sibling repositories a multi-repo
    # project needs in scope. Word-split on purpose — this is a list of flags,
    # not one string. Paths are relative to the session directory, so they stay
    # valid for anyone whose checkouts sit side by side.
    local extra; extra="$(config agent_args 2>/dev/null || true)"
    # shellcheck disable=SC2086
    exec "$agent" $extra
}

# ---------------------------------------------------------------------------
# TESTING THIS SCRIPT MUST NOT DISTURB A RUNNING MULTIPLEXER
# ---------------------------------------------------------------------------
# `worktree create` and `workspace close` are both flagged `changes_ui=true` by
# herdr: they spawn and kill panes in the session the human is looking at right
# now. Exercising create/clean against a live server therefore rearranges
# somebody's screen mid-keystroke — which is exactly what happened once.
#
# Set AGENT_WORKTREES_NO_HERDR=1 to exercise every path with git only.
have_herdr() {
    [[ -n "${AGENT_WORKTREES_NO_HERDR:-}" ]] && return 1
    command -v herdr >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# ONE SESSION, ONE WORKSPACE, ONE TAB
# ---------------------------------------------------------------------------
# Two things create a session and they used to ignore each other. Herdr opens a
# workspace with a fresh shell in it; the wrapper then runs the agent in the tab
# the human is already sitting in. Nobody ever typed into herdr's shell, so every
# session left an idle pane behind — and because the agent stayed in the tab it
# started in, the sidebar filed all of them under whatever workspace that tab
# belonged to. Three agents in three different repositories, all labelled with
# the name of the first one.
#
# So the tab moves to the session instead. The pane the human is in is pulled
# into the new workspace, and herdr's untouched shell is closed behind it. Order
# matters: move first, close second. Closing first would take the workspace's
# only pane with it, and the workspace would go too.
#
# Needs jq (the move takes an id that arrives as JSON) and HERDR_PANE_ID, which
# herdr exports into every pane it owns. Missing either one, the session still
# works exactly as before — just with the stray pane.
adopt_current_pane() {
    local created="$1" dir="$2" ws spawned
    command -v jq >/dev/null 2>&1 || return 0
    [[ -n "${HERDR_PANE_ID:-}" ]] || return 0

    ws="$(printf '%s' "$created" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)"
    spawned="$(printf '%s' "$created" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)"
    [[ -n "$ws" && -n "$spawned" ]] || return 0
    [[ "$HERDR_PANE_ID" != "$spawned" ]] || return 0

    # `--workspace` is only accepted alongside `--new-tab`; on its own the
    # command exits 2 and prints usage. Discovered by reading the exit code
    # after a pipe into jq had swallowed it and made the failure look like a
    # success.
    herdr pane move "$HERDR_PANE_ID" --new-tab --workspace "$ws" --no-focus \
        >/dev/null 2>&1 || return 0

    herdr pane close "$spawned" >/dev/null 2>&1 || true

    # The label is derived from the surviving pane's directory, and at this
    # moment that is still wherever the human typed the command — the main
    # checkout, most of the time. Left alone it reads "kamar" for a kanarix
    # session, which is the whole misfiling this function exists to end. So the
    # name is set from the session, not inferred from a directory that has not
    # caught up yet.
    herdr workspace rename "$ws" "$(basename "$2")" >/dev/null 2>&1 || true
}

cmd_new() {
    local name="${1:-}"
    local wanted="${2:-}"
    if [[ -z "$name" ]]; then
        err "Give the session a name, e.g.: agent-worktrees new payments"
        err "Hotfix off the release branch: agent-worktrees new <name> <release-branch>"
        exit 1
    fi

    # CHOOSING THE BASE MATTERS HERE, IT IS NOT COSMETIC.
    # A development branch is often far ahead of the release branch. A hotfix cut
    # from development would carry that entire payload to production alongside the
    # one line you meant to change. So the base is explicit, and the branch is
    # named differently — so `git branch` shows at a glance what targets release.
    require_origin

    local release; release="$(release_branch 2>/dev/null || true)"
    [[ -z "$wanted" ]] && wanted="$(default_base)"
    wanted="${wanted#origin/}"

    local base_ref="origin/$wanted" branch="session/$name"
    if [[ -n "$release" && "$wanted" == "$release" ]]; then
        branch="hotfix/$name"
    fi

    local dir="$PARENT/$PREFIX-$name"

    if [[ -d "$dir" ]]; then
        warn "Worktree already exists — entering the existing one."
        echo "$dir"; return 0   # stdout: path only
    fi

    # ALWAYS off a fresh remote state. Branching off a local branch would drag in
    # somebody else's uncommitted decisions and start the work from a state nobody
    # can describe.
    git -C "$MAIN" fetch origin --quiet

    if ! git -C "$MAIN" rev-parse --verify --quiet "$base_ref" >/dev/null; then
        err "No such base: $base_ref"
        exit 1
    fi

    # THROUGH HERDR WHEN IT IS AVAILABLE.
    # Herdr is a workspace manager for AI agents with its own `worktree` and
    # `agent` commands. Creating the directory behind its back works, but the new
    # session will not open in a window. So we hand it the job and only add what
    # it does not do: a fresh remote base and shared agent memory.
    if have_herdr; then
        # --no-focus: creating a session must never yank the view away from
        # whatever the human is typing in. The CLI already defaults to this;
        # saying it out loud means a change of default upstream cannot silently
        # start stealing focus.
        local created
        created="$(herdr worktree create --cwd "$MAIN" --branch "$branch" \
                     --base "$base_ref" --path "$dir" --no-focus --json 2>/dev/null)" \
            || created=""
        if [[ -n "$created" ]]; then
            # TRUST THE HAND-OVER, BUT CONFIRM IT LANDED.
            # Creating the directory is herdr's job here, so there is nothing to
            # fall back to — but announcing a session that is not on disk is
            # worse than failing: the shell function would `cd` into a path that
            # does not exist, and the error names the path rather than the cause.
            if [[ ! -d "$dir" ]]; then
                err "herdr reported success but created nothing at:"
                err "  $dir"
                printf '%s\n' "Nothing was created. Check 'herdr worktree create' by hand, or" >&2
                printf '%s\n' "re-run with AGENT_WORKTREES_NO_HERDR=1 to use plain git worktrees." >&2
                exit 1
            fi
            adopt_current_pane "$created" "$dir"
        else
            git -C "$MAIN" worktree add -b "$branch" "$dir" "$base_ref" >/dev/null
        fi
    elif git -C "$MAIN" rev-parse --verify --quiet "$branch" >/dev/null; then
        git -C "$MAIN" worktree add "$dir" "$branch" >/dev/null
    else
        git -C "$MAIN" worktree add -b "$branch" "$dir" "$base_ref" >/dev/null
    fi

    remember_base "$branch" "$base_ref"

    # ASKED, NOT ANNOUNCED. `link_memory` used to print its own line, and since
    # it runs before the block below you were told "memory: shared..." — indented
    # under nothing — and only then "Session ready". A detail arriving before its
    # heading reads like an error. It now reports back and the block says it in
    # order. Inside `if` on purpose: `set -e` is suspended there, and the answer
    # "no, not shared" is information, not a failure.
    local memory_note=""
    if link_memory "$dir"; then
        memory_note="  memory:    shared with the main repository (symlink)"
    fi

    # Everything below is for the human, so the whole block is redirected once.
    # Redirecting each call individually is how a bare `echo` slipped onto stdout
    # and prefixed the protocol line with a blank line — the wrapper then tried to
    # `cd` into "\n/path/to/session".
    {
        ok "Session ${name} ready."
        info "  directory: $dir"
        info "  branch:    $branch (off $base_ref)"
        [[ -n "$memory_note" ]] && info "$memory_note"

        if [[ "$branch" == hotfix/* ]]; then
            echo
            warn "HOTFIX — cut from $base_ref, not from the development branch."
            warn "  After releasing, MERGE THIS FIX BACK into your development branch:"
            warn "    git checkout <development-branch> && git merge $branch"
            warn "  Without that, the next release silently reverts it."
        fi
    } >&2

    # THE ONLY thing this function writes to stdout.
    echo "$dir"
}

# ---------------------------------------------------------------------------
# SHARED AGENT MEMORY ACROSS SESSIONS
# ---------------------------------------------------------------------------
# Claude Code keeps a project's history and memory in a directory named after the
# PROJECT PATH (~/.claude/projects/-Users-you-...). Every worktree has a different
# path, so without this step an agent in a new session starts with EMPTY memory:
# it cannot see the project's notes or anything agreed in earlier conversations.
#
# That is the worst kind of isolation — we set out to separate FILES and would
# have separated KNOWLEDGE by accident. So a session's memory directory is a
# symlink to the main repository's.
#
# RETURNS whether the session ends up sharing memory, and prints nothing. The
# caller says it, in its own order, next to the rest of the summary.
link_memory() {
    local dir="$1"
    local projects="$HOME/.claude/projects"
    [[ -d "$projects" ]] || return 1

    # The directory name is the path with `/` and `_` replaced by `-`.
    local key_main key_session
    key_main="$(printf '%s' "$MAIN" | tr '/_' '--')"
    key_session="$(printf '%s' "$dir" | tr '/_' '--')"

    local src="$projects/$key_main"
    local dst="$projects/$key_session"

    [[ -d "$src" ]] || return 1        # main project has no memory yet

    # Never overwrite an existing one — but a symlink that is already there is
    # shared memory, and a real directory sitting in its place is NOT. Reporting
    # both as "shared" would be a comfortable lie about the one case where an
    # agent silently starts with an empty head.
    if [[ -e "$dst" || -L "$dst" ]]; then
        [[ -L "$dst" ]] && return 0
        return 1
    fi

    ln -s "$src" "$dst" 2>/dev/null || return 1
}

# ---------------------------------------------------------------------------
# REHEARSING A MERGE — "can I safely pull the base?"
# ---------------------------------------------------------------------------
# The question comes up every time `where` reports you are behind, and answering
# it with an actual `git merge` and an undo is a bad idea: on a conflict it leaves
# the directory half-merged, in the middle of somebody's work.
#
# So the rehearsal runs ENTIRELY in the object database, never touching the
# working tree:
#   `git stash create` — builds a commit object from the working state and does
#                        NOT touch the index or the files (unlike `git stash`),
#   `git merge-tree`   — computes the merge of two commits without a checkout.
#
# A side effect that happens to be the point: the rehearsal covers UNCOMMITTED
# changes. A plain `git merge --ff-only` would not consider them at all, and would
# refuse only halfway through, complaining about overwriting local changes.
cmd_rehearse() {
    local here branch base state result
    here="$(git rev-parse --show-toplevel 2>/dev/null || echo '')"
    if [[ -z "$here" ]]; then err "Not a git repository."; exit 1; fi

    branch="$(git rev-parse --abbrev-ref HEAD)"
    base="$(base_of "$branch")"
    git fetch origin --quiet 2>/dev/null || warn "  (could not refresh origin — rehearsing against local state)"

    info "Rehearsing a merge of $base into $branch — nothing will be changed."

    local behind
    behind="$(git rev-list --count "HEAD..$base" 2>/dev/null || echo 0)"
    if [[ "$behind" == "0" ]]; then
        ok "  up to date with $base — nothing to pull"
        return 0
    fi

    # Empty result means no working changes; then we rehearse HEAD itself.
    state="$(git stash create 2>/dev/null || true)"
    [[ -n "$state" ]] || state="HEAD"

    if result="$(git merge-tree --write-tree --name-only "$state" "$base" 2>&1)"; then
        ok "  $behind commits to pull, NO conflict"
        info "  you can merge: git merge $base"
        return 0
    fi

    err "  CONFLICT — these files need a human decision:"
    echo "$result" | tail -n +2 | sed 's/^/    /' >&2
    warn "  the working directory was left UNTOUCHED — merge only when you mean to"
    return 1
}

cmd_list() {
    info "Working directories of this repository:"
    git -C "$MAIN" worktree list --porcelain | awk '
        /^worktree /   { path = substr($0, 10) }
        /^branch /     { br   = substr($0, 8); sub("refs/heads/", "", br) }
        /^detached/    { br   = "(detached HEAD)" }
        /^$/           { if (path != "") printf("  %-58s %s\n", path, br); path=""; br="" }
        END            { if (path != "") printf("  %-58s %s\n", path, br) }
    '

    # Which ones a shell is sitting in right now — this is what catches two people
    # working in the same place.
    local busy
    busy="$(lsof -a -d cwd -Fn 2>/dev/null | grep "^n$PARENT/$PREFIX" | sed 's/^n//' | sort -u || true)"
    if [[ -n "$busy" ]]; then
        echo
        info "Open in shells:"
        echo "$busy" | sed 's/^/  /'
    fi
}

# ---------------------------------------------------------------------------
# HERDR KEEPS ITS OWN REGISTRY, AND IT DOES NOT WATCH GIT
# ---------------------------------------------------------------------------
# `git worktree remove` deletes the checkout and the git bookkeeping. Herdr never
# hears about it, so its workspace list keeps an entry pointing at a directory
# that is gone. Measured on a real machine after a day of sessions: 14 entries
# against 4 real directories.
#
# Optional, not a dependency: without `jq` (or without herdr) this is a no-op and
# everything else still works. Cleaning up somebody else's registry is a nicety;
# failing the whole `clean` because a JSON parser is missing would not be.
herdr_forget() {
    have_herdr || return 0
    command -v jq    >/dev/null 2>&1 || return 0

    local path="$1" id
    id="$(herdr workspace list 2>/dev/null \
          | jq -r --arg p "$path" \
              '.result.workspaces[]? | select(.worktree.checkout_path == $p) | .workspace_id' \
              2>/dev/null)"
    id="$(first_line "$id")"
    [[ -n "$id" ]] || return 0

    herdr workspace close "$id" >/dev/null 2>&1 && info "    herdr: closed workspace $id"
}

cmd_clean() {
    info "Looking for worktrees with no changes and no commits of their own…"
    local removed=0

    while IFS= read -r path; do
        [[ -d "$path" ]] || continue
        [[ "$path" == "$MAIN" ]] && continue

        # SESSION DIRECTORIES ONLY. Without this condition the cleanup walked
        # EVERY worktree of the repository and deleted other people's — branches
        # included. Learned the hard way. "Clean up my sessions" has no business
        # touching anything else.
        [[ "$(basename "$path")" == "$PREFIX-"* ]] || continue

        # NOT THE ONE YOU ARE STANDING IN. Removing it leaves the shell in a
        # directory that no longer exists, and now that a session owns a herdr
        # workspace it also closes the tab the command was typed into.
        [[ "$path" == "$PWD" || "$PWD" == "$path"/* ]] && {
            warn "  skipping (you are in it): $path"
            continue
        }

        # Untouched means no working changes AND no commits beyond the base.
        if [[ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]]; then
            warn "  skipping (has changes): $path"
            continue
        fi
        local branch base count
        branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
        [[ -n "$branch" ]] || continue

        base="$(base_of "$branch")"

        # If counting fails the directory STAYS. An unknown state cannot mean
        # "there is nothing here" — the cost is asymmetric: a worktree left behind
        # is some disk space, a worktree deleted is somebody's work.
        if ! count="$(git -C "$MAIN" rev-list --count "$base..$branch" 2>/dev/null)"; then
            warn "  skipping (cannot count commits against $base): $path"
            continue
        fi
        if [[ "$count" != "0" ]]; then
            warn "  skipping ($count commits of its own over $base): $path"
            continue
        fi

        git -C "$MAIN" worktree remove "$path" --force >/dev/null 2>&1 || true
        herdr_forget "$path"
        # `-d`, not `-D`: a branch with unmerged commits survives. Only branches
        # without their own commits reach this point, but I would rather git had
        # the last word than my condition above.
        git -C "$MAIN" branch -d "$branch" >/dev/null 2>&1 || true
        ok "  removed: $path"
        removed=$((removed + 1))
    done < <(git -C "$MAIN" worktree list --porcelain | awk '/^worktree /{print substr($0,10)}')

    git -C "$MAIN" worktree prune
    ok "Done — removed $removed."
}

cmd_where() {
    local here
    here="$(git rev-parse --show-toplevel 2>/dev/null || echo '')"
    if [[ -z "$here" ]]; then err "Not a git repository."; exit 1; fi

    if [[ "$here" == "$MAIN" ]]; then
        warn "You are in the MAIN repository directory."
        warn "When working in parallel, start your own session: agent-worktrees"
        return 0
    fi

    local branch base behind own
    branch="$(git rev-parse --abbrev-ref HEAD)"
    base="$(base_of "$branch")"
    ok "Session: $(basename "$here")  ·  branch: $branch  ·  base: $base"

    # A warning rather than a silent merge. Pulling mid-work can drop a conflict on
    # you at the worst possible moment, so the decision stays yours — this only
    # makes sure you know you are behind.
    behind="$(git rev-list --count "HEAD..$base" 2>/dev/null || echo 0)"
    own="$(git rev-list --count "$base..HEAD" 2>/dev/null || echo 0)"
    [[ "$own" != "0" ]] && info "  commits of your own: $own"
    if [[ "$behind" != "0" ]]; then
        warn "  you are $behind commits behind $base — check safely: agent-worktrees rehearse"
    fi
}

# ---------------------------------------------------------------------------
# SELF-CHECK — "does any of this actually work?"
# ---------------------------------------------------------------------------
# Answers the question that comes up right after adopting it: how do I know this
# is working without waiting for the next collision?
cmd_verify() {
    local problems=0

    info "1. Working directory isolation"
    local count
    count="$(git -C "$MAIN" worktree list | wc -l | tr -d ' ')"
    ok "   worktrees in this repository: $count"

    info "2. Same-branch lock"
    local tmp="$PARENT/.awt-lock-test"
    local current
    current="$(git -C "$MAIN" rev-parse --abbrev-ref HEAD)"
    if git -C "$MAIN" worktree add "$tmp" "$current" >/dev/null 2>&1; then
        err "   THE LOCK IS NOT WORKING — \"$current\" was checked out twice"
        git -C "$MAIN" worktree remove "$tmp" --force >/dev/null 2>&1 || true
        problems=$((problems + 1))
    else
        ok "   git refuses to check out a branch already in use — working"
    fi

    info "3. Shared agent memory"
    local projects="$HOME/.claude/projects"
    local key_main
    key_main="$(printf '%s' "$MAIN" | tr '/_' '--')"
    if [[ -d "$projects/$key_main" ]]; then
        local linked=0
        while IFS= read -r p; do
            [[ "$(basename "$p")" == "$PREFIX-"* ]] || continue
            local k; k="$(printf '%s' "$p" | tr '/_' '--')"
            [[ -L "$projects/$k" ]] && linked=$((linked + 1))
        done < <(git -C "$MAIN" worktree list --porcelain | awk '/^worktree /{print substr($0,10)}')
        ok "   sessions with linked memory: $linked"
    else
        warn "   the main project has no memory directory yet — nothing to link"
    fi

    info "4. Herdr"
    if have_herdr; then
        ok "   available ($(herdr --version 2>/dev/null | head -1))"

        # Drift between herdr's registry and the filesystem. Reported, not fixed:
        # `clean` fixes what it removes, but entries left by a plain
        # `git worktree remove` are not this command's to delete silently.
        if command -v jq >/dev/null 2>&1; then
            local stale=0 p
            while IFS= read -r p; do
                [[ -n "$p" ]] || continue
                [[ -d "$p" ]] || stale=$((stale + 1))
            done < <(herdr workspace list 2>/dev/null \
                     | jq -r '.result.workspaces[]?.worktree.checkout_path // empty' 2>/dev/null)
            if [[ "$stale" -gt 0 ]]; then
                warn "   $stale workspace(s) point at directories that no longer exist"
                warn "   (herdr does not watch git — 'awt clean' clears the ones it removes)"
            else
                ok "   registry matches the filesystem"
            fi
        fi
        local agents
        agents="$(herdr agent list 2>/dev/null | grep -o '"cwd":"[^"]*"' | sed 's/"cwd":"//;s/"//' | sort -u || true)"
        if [[ -n "$agents" ]]; then
            info "   agents are working in:"
            echo "$agents" | sed 's/^/     /'
            local total unique
            total="$(echo "$agents" | wc -l | tr -d ' ')"
            unique="$(echo "$agents" | sort -u | wc -l | tr -d ' ')"
            if [[ "$total" != "$unique" ]]; then
                err "   TWO AGENTS IN THE SAME DIRECTORY — that is the problem this exists for"
                problems=$((problems + 1))
            fi
        fi
    else
        warn "   not in PATH — sessions will be created but will not open in a window"
    fi

    echo
    if [[ "$problems" -eq 0 ]]; then
        ok "All checks passed — the isolation is working."
    else
        err "Problems: $problems"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# `new` ALSO PUTS YOU IN THE SESSION
# ---------------------------------------------------------------------------
# The survey creates the directory, changes into it and starts the agent. `new`
# used to create the directory and leave you standing where you were, holding a
# path you then had to retype:
#
#     awt new finanse
#     cd ../kamar-base-session-finanse     <- derived by hand, from a printed path
#     claude
#
# Two of those three lines were the tool's job. `new` now answers the shell
# function with the same reply the survey does — directory, agent, arguments —
# and the function does the `cd` and starts the agent.
#
# Run WITHOUT the function (a script, CI, `agent-worktrees new x` by hand) it
# behaves exactly as before: the path on stdout and nothing else. That is the
# contract other things already depend on, and entering a session is meaningless
# to a caller that has no shell to change the directory of.
cmd_new_and_enter() {
    require_current_wrapper

    # `local dir; dir=$(...)` on two lines on purpose: `local dir=$(...)` returns
    # the status of `local`, which succeeds even when the substitution did not,
    # and a failed creation would sail on to announce a directory that is not
    # there. `set -e` takes care of the failure itself — cmd_new has already said
    # what went wrong.
    local dir
    dir="$(cmd_new "$@")"
    [[ -n "$dir" ]] || exit 1

    if [[ -n "${AWT_WRAPPER:-}" ]]; then
        # ONE FIELD PER LINE — the same protocol cmd_start replies with, and the
        # reason it is one field per line is documented there.
        local agent extra
        agent="$(session_agent)"
        extra="$(config agent_args 2>/dev/null || true)"
        # shellcheck disable=SC2086
        printf '%s\n' "$dir" "$agent" $extra
        return 0
    fi

    printf '%s\n' "$dir"
}

usage() {
    cat <<HELP
agent-worktrees — one agent, one working directory

  agent-worktrees                     SURVEY: asks for base, name and agent
  agent-worktrees new <name> [base]   no questions asked
  agent-worktrees list                every working directory and who is in it
  agent-worktrees where               where you are, off what, how far behind
  agent-worktrees rehearse            would pulling the base conflict? (changes nothing)
  agent-worktrees clean               remove worktrees with no changes and no commits
  agent-worktrees verify              check that the isolation actually works
  agent-worktrees help                this text

Configuration (.agent-worktrees.conf in the repository root, all optional):

  bases      = develop, main       which branches to offer as a base
  release    = main                the branch a hotfix targets
  agent      = claude              which agent to preselect
  agent_args = --add-dir ../other  extra flags passed to the agent

HELP
}

# ---------------------------------------------------------------------------
# A WORD THIS TOOL DOES NOT KNOW IS AN ERROR, AND MUST LOOK LIKE ONE
# ---------------------------------------------------------------------------
# It used to print the full help ON STDOUT and exit 0. So `awt finanse` — the
# most natural thing to type, and a plain typo like `awt lst` — was indeed
# answered, but with twenty lines that never said "no such command", and with
# the exit code of a success. Nothing scripting this could tell the difference
# either.
#
# Now: the complaint goes to stderr, the exit code is 2, and if the word looks
# like a session name the message says which command actually makes one. It does
# NOT create it — a typo in a subcommand also looks like a session name, and a
# tool that silently makes a branch and a directory out of a slip is worse than
# one that asks you to type six more characters.
unknown_command() {
    local word="$1"
    err "No such command: $word"

    # THE ANSWER, OR THE MENU — not both. When the word looks like a session
    # name the next command is a single line, and burying it under twenty lines
    # of help repeats the mistake this is fixing: the thing you needed scrolls
    # off the top. Anything else (a flag, a fragment) gives no such clue, so
    # there the list of commands IS the answer.
    if is_session_name "$word"; then
        {
            printf '%s\n' "If you meant a session by that name:"
            printf '%s\n' "  agent-worktrees new $word"
            printf '%s\n' ""
            printf '%s\n' "Every command: agent-worktrees help"
        } >&2
    else
        usage >&2
    fi
    exit 2
}

case "${1:-start}" in
    start|"")       cmd_start ;;
    new)            shift; cmd_new_and_enter "$@" ;;
    rehearse)       cmd_rehearse ;;
    verify)         cmd_verify ;;
    list)           cmd_list ;;
    clean)          cmd_clean ;;
    where)          cmd_where ;;
    help|-h|--help) usage ;;   # asked for, so: stdout, exit 0
    *)              unknown_command "$1" ;;
esac
