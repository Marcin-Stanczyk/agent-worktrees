# Test coverage journal

Progress log for [`TEST-COVERAGE-PLAN.md`](TEST-COVERAGE-PLAN.md). Append at the
top; never rewrite history. The plan says what should happen, this says what did.

**How to add an entry.** One block per session, newest first. Keep the four
headings — they are the ones that turned out to matter when reconstructing why a
bug survived so long:

```
## YYYY-MM-DD — <phase> — <one line>

**Done.**      what actually landed, with file paths
**Proven.**    which scenario was shown to fail against the broken version — the
               plan's definition of done requires this, so record it or the work
               is not finished
**Found.**     anything discovered that was not in the plan
**Next.**      the single next thing, not a wish list
```

If a session ends with nothing landed, still write the entry. "Tried X, it does
not work because Y" is the most valuable thing here and the first thing lost.

---

## 2026-08-08 — Phases 1 and 2 — brain-mcp: hooks tested, and retrieval moved to where the task is known

**Done.**
- `tests/hooks/test_hooks.py` — 41 scenarios, standard library only, for hooks
  that had none while `src/` had 39. Ranking, the per-session no-repeat rule, the
  new instrumentation, `project_name` folding worktrees into their parent, the
  `Stop` hook's four anti-loop guards, and for *every* hook: malformed JSON,
  empty payload, missing database, corrupt database, read-only database,
  unwritable state directory.
- `hooks/relevant_lessons.py` — a `UserPromptSubmit` hook that searches the FTS5
  index for lessons matching the prompt, **across every project**. The current
  project wins ties rather than winning outright.
- `shown_count`, `last_shown_at`, `scope` on `lessons`; `hooks/_brain_db.py` as
  the single definition of the path, the connection, the migration and the FTS
  sanitiser; `STATE_DIR` reduced from two definitions to one.
- CI runs the hook suite; `install-hooks.mjs` registers the new hook.

**Proven.** Three deliberate regressions turned the suite red:
- cross-project search reverted to a project filter → *"finds a lesson filed
  under a different project"* FAILED.
- `updated_at` touched when recording a show → *"showing a lesson does not make
  it look freshly written"* FAILED.
- instrumentation removed → *"records that a lesson was shown"* FAILED.

**Found.**
- **The second proof passed on the first attempt, and the test was wrong, not the
  code.** The fixture inserted rows with `datetime('now')`, so `updated_at` and
  the hook's write landed in the same second and the assertion held either way.
  Pinned to a fixed past instant. Generalises: any test asserting *"this
  timestamp did not change"* is worthless unless the fixture's timestamp is
  distinguishable from the one under test.
- The `lessons_au` trigger re-indexes FTS on every `UPDATE`, so instrumentation
  writes cost an FTS delete+insert per shown lesson. Three per prompt — measured
  as negligible, recorded so it is not rediscovered as a mystery.
- `grep` in this environment returns empty results for patterns that plainly
  match; searching with Python was the workaround. Worth knowing before
  concluding a symbol does not exist.

**Demonstrated.** A session in `kamar` asking *"my bash script dies with exit 141
and pipefail, no message"* now receives lesson #296, which is filed under
`agent-worktrees`. Under the old mechanism that lesson was invisible outside its
own repository, permanently — the exact repeat-mistake shape that prompted this
work.

**Next.** Let `shown_count` accumulate for a week, then read it before touching
ranking again. Phase 4 (`brain-mcp`'s MCP surface beyond the happy path) is
untouched, and so is the idea of a `PreToolUse` guard that surfaces a lesson
*before* a risky command rather than after — deliberately not built yet, because
a noisy guard in a daily driver is how the whole system gets uninstalled.

---

## 2026-08-08 — Phase 3 — herdr, rehearse, where and the installer; CI turned red first

**Done.**
- 15 more scenarios in `test/run.sh` (19 → 34). Herdr behind a fake on `PATH`
  that genuinely creates the worktree and records its argv: hand-over flags,
  fallback when the hand-over fails, `adopt_current_pane` (move BEFORE close,
  asserted by line order; rename after the session, not the directory), the
  `HERDR_PANE_ID`-absent path, `herdr_forget` on `clean`, and the no-match case.
  Plus `rehearse` against a real conflict, `where` arithmetic, `clean` with the
  base moved underneath a session, and `install.sh` into a throwaway `HOME`
  (symlinks, idempotence, the stale-pasted-function warning, the herdr notice).
- CI now installs `zsh` on the Linux runner.

**Proven.** The new guard was reverted and *"herdr: a hand-over that reports
success but creates nothing"* failed with `want [1], got [0]`.

**Found.**
- **CI caught its own first bug immediately**: the Linux runner has no `zsh`, so
  the very check that exists to stop bash/zsh drift was silently absent there.
  macOS passed. Without the second platform this would have looked green.
- **A hand-over that succeeds without creating anything was not caught.** The
  fake herdr initially did not create the worktree, which failed the test — and
  the failure was correct: the tool trusted the JSON, announced a ready session
  and printed a path that was not on disk, so the shell function would `cd` into
  nothing and blame the path rather than the cause. Now guarded, with the
  fallback advice (`AGENT_WORKTREES_NO_HERDR=1`) in the message.
- **The suite was reading the developer's environment.** `HERDR_PANE_ID` is
  exported into every herdr pane, so the "no pane is touched" scenario passed or
  failed depending on which terminal the suite was started from. Cleared
  explicitly in every runner now. Worth remembering as a class: a fake on `PATH`
  isolates the *binary*, not the *environment it reads*.
- Heredoc discipline: an unquoted heredoc expanded `$#`/`$1` while *writing* the
  fake, producing a script that silently did nothing and made four unrelated
  scenarios fail with empty call logs.

**Next.** Phase 1: `brain-mcp`'s hooks.

---

## 2026-08-08 — Phase 0 — first tests, and three bugs that predate them

**Done.**
- `test/run.sh` — 19 scenarios, plain bash, no bats. Isolated `HOME` and
  `AGENT_WORKTREES_NO_HERDR=1` per scenario; each builds a real bare repo plus a
  clone so `origin/<branch>` is genuine.
- `.github/workflows/test.yml` — Linux + macOS, shellcheck, and a second run
  under `/bin/bash` (3.2 on macOS).
- `awt.sh` — the shell function, now one file instead of two drifting copies,
  POSIX so bash and zsh both run it. `install.sh` symlinks it.
- Fixes: `default_base` SIGPIPE; line-per-field wrapper protocol; `require_origin`.

**Proven.** All three fixes were reverted one at a time and the suite went red
each time, with the right scenario failing:
- `default_base` restored → *"new: no base given"* fails with `want [0], got [141]`.
- `${=args}` restored → *"awt() parses the protocol"* fails, the argument
  `one two` arriving as two arguments.
- `require_origin` removed → *"no origin"* fails with `want [1], got [128]`.

**Found.**
- `agent-worktrees new <name>` without an explicit base had never worked in any
  repository — exit 141, empty stdout, empty stderr, no worktree. The interactive
  survey hid it because it reads `detect_bases` through a process substitution,
  where the status is discarded.
- `install.sh` carried its own copy of the shell function, one protocol version
  behind, and parsed the agent's *arguments* as the agent's *name*. Since the
  README says to start with `./install.sh`, that broken copy is the one every new
  user got, while anyone who already had the good copy in their shell config saw
  nothing wrong.
- The README's copy used zsh's `${=args}`, a `bad substitution` in bash — and
  `install.sh` selects `.bashrc` whenever there is no `.zshrc`.
- A repository without an `origin` remote failed with a completely silent
  `exit 1`.
- Fixture paths must be resolved with `pwd -P`: on macOS `$TMPDIR` is under
  `/var`, a symlink to `/private/var`, and the tool resolves physically — the
  memory-symlink scenario failed on that alone.

**Next.** Phase 1: tests for `brain-mcp`'s three hooks, starting with
`session_context.py`, and the "no hook may crash a session" scenarios.

---

## 2026-08-08 — Phase 2 (survey only) — what the numbers say about recall

No code. Recorded here because the plan's Phase 2 depends on it and the question
came from outside the plan: *are the stored lessons actually preventing repeated
mistakes?*

**Found.** Measured against the live database — 297 lessons, 22 projects:
- 6 of 297 lessons (2%) can ever be seen outside the project they were filed
  under. `GLOBAL_PROJECTS` is `claude-code-setup` alone, and only `critical`
  entries cross over.
- A session in `kamar` sees 12 of 124. There are 60 `critical` lessons there, so
  the twelve slots never reach `important` or `info` at all: 64 lessons are
  structurally unreachable.
- Ranking is severity then `updated_at DESC`. Recency, never relevance to the
  task at hand.
- The `SessionStart` hook does no semantic search. The embeddings layer in
  `src/` is opt-in, `BRAIN_EMBEDDINGS_URL` is unset, and the database holds
  zero vectors. The FTS index the schema maintains is not queried by the hook.
- Writing is enforced by a **blocking** Stop hook. Reading is a single 220-char
  preview at session start and nothing afterwards. Nothing prompts a `brain_recall`
  at the moment a lesson would help.
- `lessons` has no usage column of any kind, so neither the system nor its author
  can measure whether any of this works.

**Demonstrated on this very session.** The four lessons injected at start were
about GitHub Projects statuses, a WAF diff, NUL bytes from the Write tool and
sandbox DNS — none related to auditing a bash script. And lesson #296, recorded
today, is the `pipefail` + `head` trap: filed under `agent-worktrees`, so it will
**not** surface in `kamar` or anywhere else. The next time that trap appears in
another repository, nothing will mention it.

**Next.** Phase 2 step 1 only: usage instrumentation. Do not touch ranking until
there are numbers.
