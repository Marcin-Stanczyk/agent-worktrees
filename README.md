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
awt help                 the above
```

**Both `awt` and `awt new` leave you standing in the session with the agent
running.** The survey asks which agent; `new` takes the one from
`.agent-worktrees.conf` (or `claude`) without asking, which is what "no questions
asked" means. `new` used to create the directory and leave you where you were,
holding a path you then had to retype — two of those three commands were the
tool's job:

```
awt new finanse
cd ../kamar-base-session-finanse    # derived by hand from a printed path
claude
```

Run **without** the shell function — a script, CI, `agent-worktrees new x` by
hand — `new` prints the session path on stdout and does nothing else. Entering a
directory is meaningless to a caller with no shell to enter it in, and the path
on stdout is what those callers already read.

### A word this tool does not know is an error

`awt finanse` is the most natural thing to type, and it is not a command. It used
to print the full help **on stdout** and exit **0**, so a typo was
indistinguishable from success — to you and to anything scripting this. Now it
goes to stderr, exits 2, and if the word looks like a session name it says which
command actually makes one:

```
$ awt finanse
No such command: finanse
If you meant a session by that name:
  agent-worktrees new finanse

Every command: agent-worktrees help
```

It does **not** create it. A mistyped subcommand also looks like a session name,
and a tool that silently makes a branch and a directory out of a slip is worse
than one that asks for six more characters.

Standing outside a repository, the refusal names the repositories directly below
you, because the directory holding a project's checkouts is where you usually
are when you get this wrong:

```
$ awt finanse
Not inside a git repository.
Repositories directly below here:
  cd kamar-base
  cd kamar-checkout
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

`install.sh` symlinks two things: the tool into `~/.local/bin`, and the shell
function into `~/.local/share/agent-worktrees/awt.sh`. Then it prints one line to
add to your shell config:

```sh
[ -f "$HOME/.local/share/agent-worktrees/awt.sh" ] && . "$HOME/.local/share/agent-worktrees/awt.sh"
```

It has to be a **function, not an alias**: only a function can change the current
shell's directory, and an alias cannot capture the tool's output.

**Source it, do not paste it.** The function and the tool speak a protocol to
each other, and a pasted copy cannot follow a change to that protocol. There used
to be two pasted copies — one in this README, one in `install.sh` — and they
drifted: the installer stayed on an older two-field format and read the agent's
*arguments* as the agent's *name*, so it tried to run `--add-dir` as a command.
Because the README told you to start with `./install.sh`, the broken copy is the
one every new person got, while everyone who already had the good one in their
shell config saw nothing wrong. The file at
[`awt.sh`](awt.sh) is now the only copy, and `git pull` updates it with the tool.

If you already pasted an `awt()` function into your shell config, delete it —
`install.sh` will warn you if it spots one.

The function is written in POSIX shell so the same file works in **bash
(including the 3.2 that macOS ships) and zsh**. The earlier README version used
zsh's `${=args}`, which is a `bad substitution` in bash — and `install.sh` picks
`.bashrc` whenever there is no `.zshrc`, so it was actively pointing part of a
team at the shell where its own snippet did not run.

## Testing

```bash
./test/run.sh                      # every scenario
./test/run.sh wrapper              # only scenarios matching "wrapper"
BASH_UNDER_TEST=/bin/bash ./test/run.sh    # against macOS's bash 3.2
```

Plain bash, no `bats` and no assertion library — the tool refuses to depend on
anything you have to install first, and a suite that broke that promise would not
get run by the people most likely to find bugs.

Every scenario builds its own bare repository plus a clone, so `origin/<branch>`
is real rather than simulated, and runs with `AGENT_WORKTREES_NO_HERDR=1` and a
throwaway `HOME`. Without the first it would rearrange the panes of whoever is
using herdr right now; without the second it would write symlinks into your real
`~/.claude/projects`.

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

**Optional, and deliberately kept that way.** If Herdr is on your `PATH`,
worktree creation is handed to it, so the session opens in its own window and
shows up in its agent list. Without it everything still works — the session just
will not open a window by itself. `install.sh` says so once, and
`agent-worktrees verify` reports it every time; neither offers to install it.

That is a decision, not an omission. Making Herdr compulsory — even behind a
friendly "install it?" prompt — would cost this tool the one property that lets
it be dropped into any repository on any machine, and a prompt is unsafe here
besides: stdout carries the protocol the shell function parses, so anything
asking a question has to be careful about which channel it speaks on. If your
*team* wants to standardise on Herdr, that belongs in the project's
`.agent-worktrees.conf`, not in the tool.

**Set `AGENT_WORKTREES_NO_HERDR=1` before testing this tool.** `new` and `clean`
both rearrange Herdr's panes. If someone is working in that Herdr right now — and
while you are testing, that someone is usually you in the other window — their
layout shifts under their hands mid-sentence. The variable makes both commands
fall back to plain worktree operations and touch nothing visual.

```bash
AGENT_WORKTREES_NO_HERDR=1 agent-worktrees new spike/whatever
```

## Traps

**Run it from the repository you are working on, not from this one.** Every
command resolves branches and worktrees relative to the current directory. Run
`new` from this tool's own checkout and you get `No such base: origin/prod`,
because this repository has no such branch. Run `clean` there and it reports
`removed 0`, because there is nothing to remove. Both messages are accurate and
both read like the tool is broken. It is not — you are standing in the wrong
directory.

**Moving the parent directory breaks every worktree link.** A linked worktree
stores an absolute path in its `.git` file, and the main repository stores the
matching absolute path in `.git/worktrees/*/gitdir`. Rename or move the directory
holding them and git stops resolving in either direction. The repair is one
command from the main checkout:

```bash
git worktree repair --relative-paths     # needs a git new enough to have the flag
```

`--relative-paths` rewrites the links relative, so the *next* move needs no
repair at all. Run it once after any reorganisation and the problem stops
recurring.

Two things it does **not** fix, because they are not git's to fix: your agent
tool's session history, if that is keyed by directory path, and any terminal
workspace manager storing absolute working directories. Check both before moving
anything you would miss.

## Requirements

`git` 2.38 or newer (for `merge-tree --write-tree`) and `bash`. Tested on macOS
against the system bash 3.2, so it avoids constructs that need bash 4+. The shell
function is POSIX and works in bash and zsh alike.

A remote called **`origin`** — every base a session is cut from is a remote
branch, so a repository without one is refused with an explanation rather than
the silent `exit 1` it used to give.

Nothing else is required. `herdr` and `jq` are both optional and both degrade to
a no-op; see below.

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
