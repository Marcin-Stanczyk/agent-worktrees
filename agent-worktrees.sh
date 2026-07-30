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
    printf '%s\n' "Change into the project you want a session for and try again." >&2
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
config() {
    local file="$MAIN/.agent-worktrees.conf" key="$1"
    [[ -f "$file" ]] || return 1
    sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$file" \
        | sed 's/[[:space:]]*$//' | head -1 | grep . || return 1
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

default_base() {
    detect_bases | head -1
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

read_line() {
    local l
    read -r l || l=""
    printf '%s' "$l"
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
        pick="$(read_line)"; pick="${pick:-1}"
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
        name="$(read_line)"
        # A slug: no spaces, no characters that surprise you in a branch or
        # directory name. Rejecting and asking again beats silently rewriting
        # what somebody typed.
        if [[ "$name" =~ ^[a-z0-9][a-z0-9-]{1,38}$ ]]; then
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

cmd_start() {
    local base name agent preferred release

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
    local confirm; confirm="$(read_line)"
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
        # Three tab-separated fields: directory, agent, extra arguments. The
        # third may be empty; the shell function must still split on tabs, not
        # on whitespace, or a multi-flag argument list would fall apart.
        printf '%s\t%s\t%s\n' "$dir" "$agent" "$(config agent_args 2>/dev/null || true)"
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
        echo "$dir"; return 0
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
    if command -v herdr >/dev/null 2>&1; then
        herdr worktree create --cwd "$MAIN" --branch "$branch" --base "$base_ref" --path "$dir" >/dev/null 2>&1 \
            || git -C "$MAIN" worktree add -b "$branch" "$dir" "$base_ref" >/dev/null
    elif git -C "$MAIN" rev-parse --verify --quiet "$branch" >/dev/null; then
        git -C "$MAIN" worktree add "$dir" "$branch" >/dev/null
    else
        git -C "$MAIN" worktree add -b "$branch" "$dir" "$base_ref" >/dev/null
    fi

    remember_base "$branch" "$base_ref"
    link_memory "$dir"

    ok "Session ${name} ready."
    info "  directory: $dir"
    info "  branch:    $branch (off $base_ref)"

    if [[ "$branch" == hotfix/* ]]; then
        echo
        warn "HOTFIX — cut from $base_ref, not from the development branch."
        warn "  After releasing, MERGE THIS FIX BACK into your development branch:"
        warn "    git checkout <development-branch> && git merge $branch"
        warn "  Without that, the next release silently reverts it."
    fi

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
link_memory() {
    local dir="$1"
    local projects="$HOME/.claude/projects"
    [[ -d "$projects" ]] || return 0

    # The directory name is the path with `/` and `_` replaced by `-`.
    local key_main key_session
    key_main="$(printf '%s' "$MAIN" | tr '/_' '--')"
    key_session="$(printf '%s' "$dir" | tr '/_' '--')"

    local src="$projects/$key_main"
    local dst="$projects/$key_session"

    [[ -d "$src" ]] || return 0        # main project has no memory yet
    [[ -e "$dst" ]] && return 0        # never overwrite an existing one

    ln -s "$src" "$dst" 2>/dev/null && \
        info "  memory:    shared with the main repository (symlink)"
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
    if command -v herdr >/dev/null 2>&1; then
        ok "   available ($(herdr --version 2>/dev/null | head -1))"
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

case "${1:-start}" in
    start|"") cmd_start ;;
    new)      shift; cmd_new "$@" ;;
    rehearse) cmd_rehearse ;;
    verify)   cmd_verify ;;
    list)     cmd_list ;;
    clean)    cmd_clean ;;
    where)    cmd_where ;;
    *)
        cat <<HELP
agent-worktrees — one agent, one working directory

  agent-worktrees                     SURVEY: asks for base, name and agent
  agent-worktrees new <name> [base]   no questions asked
  agent-worktrees list                every working directory and who is in it
  agent-worktrees where               where you are, off what, how far behind
  agent-worktrees rehearse            would pulling the base conflict? (changes nothing)
  agent-worktrees clean               remove worktrees with no changes and no commits
  agent-worktrees verify              check that the isolation actually works

Configuration (.agent-worktrees.conf in the repository root, all optional):

  bases      = develop, main       which branches to offer as a base
  release    = main                the branch a hotfix targets
  agent      = claude              which agent to preselect
  agent_args = --add-dir ../other  extra flags passed to the agent

HELP
        ;;
esac
