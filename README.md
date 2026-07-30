# agent-worktrees

**One agent, one working directory.** A small tool that gives every parallel AI
coding session its own checkout of the same repository, so two agents cannot
overwrite each other's work.

```bash
git clone https://github.com/Marcin-Stanczyk/agent-worktrees.git
cd agent-worktrees && ./install.sh
```

Then run `awt` from inside **any** git repository.

---

## The problem

Two AI agents were working in the same checkout of the same repository. One
agent's commit swallowed the other's uncommitted files, and a rebase rewrote
hashes that had already been pushed. A whole feature survived only because
somebody noticed in time.

That was nobody's carelessness. With a single checkout, **`git add` has no way to
tell one agent's files from another's** — it sees one index. No amount of
discipline fixes that, because the information simply is not there.

## The solution git already ships

`git worktree` gives you one repository (shared objects and refs) with **many
independent working directories**, each with its own checkout and its own index.
Two sessions physically cannot overwrite each other's files.

Better still: **git refuses to check out the same branch in two worktrees at
once.** That is a built-in lock, not a convention you have to remember.

### What worktrees do not solve

Objects and refs are shared, so `rebase`, `commit --amend` and `push --force` on
a **pushed** branch still destroy the other person's work. A worktree protects
the working directory, not history. That part stays a human agreement.

## What this tool adds

`git worktree` is the right primitive but a clumsy daily interface. This wraps it
with four things it does not do on its own.

**A survey instead of remembered syntax.** One word, then questions: which base,
what name, which agent. Plain bash — no `gum`, `fzf` or `whiptail`, so there is
nothing to install first.

**It remembers what each session was cut from.** Every later question — "how many
commits are mine", "am I behind" — only makes sense against *that* base. Counting
against a fixed branch produces numbers that are wrong in the worst direction: a
session holding real work can report zero and qualify for deletion.

**Hotfix branches are marked and hard to confuse.** A branch cut from the release
branch is named `hotfix/*` rather than `session/*`, so `git branch` shows at a
glance what targets production. The tool also reminds you to merge the fix back
into your development branch — without that, the next release silently reverts
it, which is the hardest kind of regression to spot because nobody broke
anything.

**Shared agent memory.** Claude Code keys a project's memory to its *path*, so a
new worktree means an agent that starts with no memory of the project. That is
the worst possible outcome: you set out to separate files and separate knowledge
by accident. Session memory is symlinked to the main repository's.

## Usage

```
awt                      survey: base, name, agent
awt new <name> [base]    no questions asked
awt list                 every working directory and who is in it
awt where                where you are, off what, how far behind
awt rehearse             would pulling the base conflict? (changes nothing)
awt clean                remove worktrees with no changes and no commits
awt verify               check that the isolation actually works
```

### `rehearse` — the one worth knowing about

"Can I safely pull the base?" comes up constantly, and answering it with a real
`git merge` plus an undo is a bad idea: on a conflict it leaves the directory
half-merged, in the middle of somebody's work.

The rehearsal runs entirely in the object database. `git stash create` builds a
commit object from your working state **without touching the index or the
files**, and `git merge-tree` computes the merge without a checkout.

A side effect that happens to be the point: **it covers uncommitted changes.** A
plain `git merge --ff-only` would not consider them at all, and would refuse only
halfway through, complaining about overwriting local changes.

### `clean` is deliberately timid

It touches **only** directories carrying the session prefix, and only those with
neither changes nor commits of their own. If it cannot count commits for any
reason, the directory stays.

The cost is asymmetric: a worktree left behind is some disk space, a worktree
deleted is somebody's work. An earlier version walked every worktree in the
repository and removed branches that were none of its business. That is why the
condition is this narrow.

## Configuration

Optional. Drop `.agent-worktrees.conf` in the repository root:

```ini
bases      = develop, main         # which branches to offer as a base
release    = main                  # the branch a hotfix targets
agent      = claude                # which agent to preselect
agent_args = --add-dir ../api      # extra flags passed to the agent
```

`agent_args` earns its place on **multi-repository projects**: a worktree only
ever contains one repository, so an agent that needs its siblings in scope has to
be told. Paths are relative to the session directory, which keeps them valid for
anyone whose checkouts sit side by side.

Without it, the tool looks for the conventional names — `develop`, `dev`,
`staging`, `stage`, `main`, `master`, `production`, `prod` — and offers the ones
that actually exist on the remote.

The file is **parsed strictly, never sourced**: reading configuration with
`source` means a file in a project directory gets to execute arbitrary code, and
that is not a risk worth taking for something this simple.

## Shell integration

`install.sh` symlinks the script into `~/.local/bin` and prints this block for
your shell config. It has to be a **function, not an alias**: only a function can
change the current shell's directory, and an alias cannot capture the script's
output.

```zsh
awt() {
    local cli="$HOME/.local/bin/agent-worktrees"
    case "${1:-start}" in
        start|"")
            # A process cannot change its parent shell's directory. So the script
            # hands us the path and the agent, and we do the `cd` here — which is
            # also why you stay in the session after the agent exits.
            local out dir rest agent args
            out="$(AWT_WRAPPER=1 "$cli" start)" || return 1
            dir="${out%%$'\t'*}"; rest="${out#*$'\t'}"
            agent="${rest%%$'\t'*}"; args="${rest#*$'\t'}"
            cd "$dir" || return 1
            [[ "$agent" == "plain shell" ]] && return 0
            "$agent" ${=args}   # ${=} forces word splitting in zsh
            ;;
        *) "$cli" "$@" ;;
    esac
}
```

Name it whatever you like — the function lives in your shell config, not in this
repository.

## What it looks like

```
$ awt

Cut the session off what?
   1) develop
   2) main — HOTFIX, goes straight to release
   choice [1]:

Session name (directory, branch and window all get it)
   name: payments

Which agent should start?
   1) claude
   2) gemini
   3) plain shell
   choice [1]:

About to create:
   branch:    session/payments
   base:      origin/develop
   directory: .../myrepo-session-payments
   agent:     claude
   Enter to confirm, anything else to abort:
```

Enter, and you are in the new directory with the agent running.

## Herdr

If Herdr is on your `PATH`, worktree creation is handed to it, so the session
opens in its own window and shows up in its agent list. Without it everything
still works — the session just will not open a window by itself.

## Requirements

`git` 2.38 or newer (for `merge-tree --write-tree`) and `bash`. Tested on macOS
against the system bash 3.2, so it avoids constructs that need bash 4+.

## Rules a worktree cannot enforce for you

1. **One branch, one session.** Never shared.
2. **Never `git add -A` or `git commit -a`** — always explicit paths. That is
   precisely what made the bad commit separable after the fact.
3. **No history rewriting** on anything already pushed.
4. **A contract in code beats a protocol in someone's memory.** When two agents
   must touch the same area, have each guard its own entry point rather than
   agreeing on an order of operations.

## License

MIT
