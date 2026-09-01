# Resume a worktree, and clean one worktree at a time

Two gaps in daily use of `awt`, both raised together on 2026-08-31:

1. There is no way back into a session you already started except knowing its
   exact name (or `cd`-ing there by hand). `new <existing-name>` happens to
   re-enter an existing worktree as a side effect of its "is this name already
   taken" check, but that is not a documented entry point and it cannot be
   browsed — you have to already know the name.
2. `clean` is all-or-nothing on purpose: only a worktree with **zero** changes
   and **zero** commits of its own is touched, everything else is left forever.
   That is the right default (see README, "clean is deliberately timid"), but
   it leaves no path for "yes, I know this one has commits, I already got what
   I needed from it, remove it" — the only way to do that today is `git
   worktree remove` and `git branch -d` by hand, off camera from this tool.

## What already exists — not rebuilding any of this

- `worktree_paths`, `is_worktree_of_ours`, `is_session_branch`, `base_of` —
  provenance and status primitives `clean`/`verify`/`where` already use.
- `choose()` / `ask_base()` / `read_line()` / `no_more_input()` — the survey's
  menu and input handling, including EOF-safety.
- The wrapper reply protocol (`AWT_WRAPPER`, one field per line: directory,
  agent, extra args) that `start` and `new` already speak, and `awt.sh`
  already parses.
- `have_herdr` / `herdr_forget` — herdr integration, untouched.
- The busy-shell detection in `cmd_list` (`lsof -a -d cwd`) — reused, not
  reimplemented, by factoring it out into its own function.
- `cmd_clean`'s provenance and safety guards (only `is_session_branch`
  worktrees, never `MAIN`, never the directory you are standing in) — carried
  over unchanged into the interactive path. Interactive mode relaxes the
  "no changes, no commits" restriction, because that is the entire point of
  asking a human instead of deciding automatically; it does not relax which
  worktrees are eligible at all.

## Step 1/2 — `agent-worktrees resume [name]`

Usable on its own: jump straight back into a session.

- `resume <name>` — no questions asked, same contract as `new <name>`: resolve
  `$PARENT/$PREFIX-$name`, refuse if it is not a worktree of this repository,
  hand the shell function the directory and the configured agent.
- `resume` with no name — requires a terminal (same `should_ask` rule as
  everywhere else this tool asks a question). Lists every worktree but
  `MAIN`, one line each: directory, branch, dirty/clean, commits ahead/behind
  its base, and whether another shell already has it open. `choose()` a
  numbered menu, then `choose()` an agent the same way the survey does.
- Resuming a worktree another shell already has open is flagged loudly before
  the confirmation, because starting a second agent in the same directory is
  the exact failure this whole tool exists to prevent — it does not block it,
  since the busy signal is a heuristic (a shell sitting in a subdirectory can
  be a leftover terminal, not a running agent), but it must never be silent.

## Step 2/2 — `agent-worktrees clean -i` / `--interactive`

Depends on Step 1 only for the shared status-line and busy-detection helpers;
branches off `main` after Step 1 has merged, not off Step 1's branch.

- Shows the full picture first: every worktree but `MAIN`, same status line as
  `resume`'s menu, with the ones `clean` would never touch (not ours, `MAIN`,
  the one you are standing in) marked as excluded and why.
- Then goes through the remaining candidates one at a time — oldest-created
  first is not tracked anywhere, so worktree-list order, which is what git
  itself uses — asking `Remove <name>? [y/N/q]`. `y` removes it right there
  (same removal code the automatic path uses: `worktree remove --force`,
  `herdr_forget`, `branch -d`), Enter or `n` skips it, `q` stops asking and
  leaves everything not yet decided untouched.
- Default answer is always "skip". The cost is asymmetric — a worktree left
  behind is disk space, one removed is somebody's work — and that asymmetry
  is the reason automatic `clean` is timid in the first place; interactive
  mode changes who decides, not which way an unanswered question falls.

## Explicitly not doing here

- No stored, human-authored "description" per session — there is no such
  field in `.agent-worktrees.conf` or anywhere else today, and inventing one
  is a separate feature nobody asked for. The branch name is the description
  the tool already has.
- No diff or log viewer inside `clean -i` — the status line (dirty/clean,
  ahead/behind) is the information `clean`'s existing skip messages already
  consider decision-relevant; a full diff view is a bigger feature on its own.
- No change to automatic `clean`'s existing behaviour or its "no changes, no
  commits" condition. Worth a note for later: automatic `clean` does not check
  whether a worktree is busy, so a session with a shell already open but no
  commits yet is currently eligible for silent removal. That is a pre-existing
  gap, not part of either feature requested here, and changing existing
  behaviour is a separate bug-fix lane — not touched in this plan.

## Testing

Both steps get scenarios in `test/run.sh`, same fixture style
(`make_repo`/`make_repo_as`, `AGENT_WORKTREES_NO_HERDR=1`, throwaway `HOME`).
Both must keep `./test/run.sh` and `BASH_UNDER_TEST=/bin/bash ./test/run.sh`
green, and keep `shellcheck -s bash -e SC2001,SC2016 agent-worktrees.sh
install.sh test/run.sh` clean without adding to the exclusion list — new code
follows the file's existing `local x; x="$(...)"` split-assignment style so it
does not trip SC2155, exactly like everything already in this file does.

## PRs

One branch, one PR per step, in this order:

1. `feature/resume-worktree` — plan doc (this file) + Step 1.
2. `feature/clean-interactive` — Step 2, branched off `main` once (1) is
   merged.
