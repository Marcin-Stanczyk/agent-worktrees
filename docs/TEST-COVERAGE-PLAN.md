# Test coverage plan — `agent-worktrees` and `brain-mcp`

Written in English to match both repositories, which are public and entirely in
English. The working journal beside it ([`TEST-COVERAGE-JOURNAL.md`](TEST-COVERAGE-JOURNAL.md))
is the file to update as work lands; this file changes only when the *plan*
changes.

## Why this exists

An audit of `agent-worktrees` on 2026-08-08 found, in about twenty minutes, that
one of the two documented commands had **never worked in any repository** and
that `install.sh` handed every new user a broken shell function. Both projects
had been used daily for months. Neither failure was subtle; both were simply
never executed by anyone in a position to notice.

The pattern is the point:

> **Both projects have a well-tested or well-reasoned core and an untested
> boundary — and every bug found so far lives on the boundary.**

- `agent-worktrees`: clean under shellcheck, careful about channel discipline,
  bash-3.2-safe. The bugs were in `install.sh`, in the shell function, and in the
  one code path that only runs non-interactively.
- `brain-mcp`: 39 passing tests, all of `src/` (the MCP server). **Zero tests of
  `hooks/`** — which is the entire mechanism by which anything ever reaches an
  agent's context.

So this plan is not "raise coverage to N%". Coverage percentage would have been
high for both projects on the day both were broken. It is: **enumerate the ways
each project meets the outside world, and put a scenario on each one.**

## Definition of done, per scenario

A scenario counts as covered when all three hold:

1. It runs in CI on **Linux and macOS** (macOS matters: the worst bug was a
   bash-3.2/`pipefail` interaction).
2. **Reverting the fix turns it red.** Untested tests are worse than no tests —
   they buy confidence without paying for it. Every scenario added under this
   plan must be demonstrated to fail against the broken version, and the journal
   records that demonstration.
3. It needs nothing installed that the project itself does not already need.

## Phases

Phases are ordered by *expected bugs per hour*, not by tidiness. Each is sized to
fit one session.

---

### Phase 0 — `agent-worktrees`: the boundary that was broken ✅ done 2026-08-08

19 scenarios in `test/run.sh`: session creation (explicit base, default base,
hotfix, duplicate, bad base), no-`origin` and non-repository refusals, config
parsing, the wrapper protocol, the `awt()` function in **bash and zsh**, `clean`
retention rules, the read-only commands, the same-branch lock, memory
symlinking, and herdr degradation. CI on Linux + macOS, plus a second run under
`/bin/bash` 3.2.

All three fixed bugs were confirmed to turn the suite red before the fix.

---

### Phase 1 — `brain-mcp`: the hooks ✅ done 2026-08-08

**The largest gap in either project.** `hooks/session_context.py` (383 lines),
`hooks/capture_lesson.py` and `hooks/incident_watch.py` have no tests at all, and
they are the only reason brain-mcp affects anything.

A hook is a pure function of (stdin payload, database, cwd) → (stdout, exit
code). That is trivially testable and currently untested.

- `session_context`: project resolution from cwd, including the worktree case
  (`myapp-hotfix` must inherit `myapp`); lesson selection and ordering;
  `MAX_LESSONS` / `MAX_GLOBAL_CRITICALS` / `SNIPPET_CHARS` / `MAX_CHARS` limits
  actually enforced; graph-drift detection; **behaviour when the database is
  missing, locked, or corrupt — a session must start anyway**.
- `capture_lesson`: blocks at most once per session; never blocks when
  `stop_hook_active`; marker-file lifecycle; the incident-listing path.
- `incident_watch`: what it classifies as an incident, and what it ignores.
- Cross-cutting: **no hook may ever crash a session.** One scenario per hook
  feeding it malformed JSON, an empty payload, and a read-only filesystem.

### Phase 2 — `brain-mcp`: retrieval, as a measurable property ⏳ steps 1–2 done 2026-08-08

This phase is different from the others: it cannot be written until a design
question is answered, and the question is the one that prompted this work —
*do the lessons actually prevent repeated mistakes?*

Today the honest answer is **nobody can tell**, and that is a property of the
schema, not of the lessons. `lessons` has `created_at` and `updated_at` and
nothing else: no record of a lesson ever being retrieved, shown, or used. The
system cannot report its own hit rate, and neither can its author.

Measured facts as of 2026-08-08 (297 lessons, 22 projects):

| Fact | Value |
|---|---|
| Lessons visible outside their own project | **6 of 297** (2%) |
| Lessons a session in `kamar` can see | **12 of 124** (10%) |
| `kamar` lessons that are `critical` | 60 — so the 12 slots are filled by criticals alone |
| `kamar` lessons at `important`/`info` | 64, **structurally unreachable** by the hook |
| Retrieval ranking | severity, then `updated_at DESC` — recency, never relevance |
| Semantic search in the hook | none; embeddings exist in `src/` but are opt-in and currently **off** (0 vectors stored) |
| Enforcement | writing is a **blocking** Stop hook; reading is a one-shot 220-character preview |

That asymmetry is the finding. The system is very good at *capturing* lessons and
close to inert at *recalling* them at the moment one would help.

So Phase 2 is, in order:

1. **Instrument first.** Add usage columns (`shown_count`, `last_shown_at`, and a
   session id) written by the hook. Cheap, non-breaking, and it converts "I think
   it isn't working" into a number. Tests: the counters move exactly when a
   lesson is injected, and never otherwise.
2. **Then decide what correct retrieval is** — relevance to the current task,
   not recency within a project. Candidates: turn on the existing embeddings
   layer; use the FTS index the schema already maintains and nobody queries from
   the hook; widen `GLOBAL_PROJECTS`; add a `scope: global` flag at write time
   for lessons that are about a *tool* rather than a *project* (today's bash
   `pipefail` trap is exactly that, and it is invisible outside one repository).
3. **Then test it** against a fixture corpus with known right answers — a set of
   (task description → lesson that should surface) pairs, so a ranking change can
   be shown to help rather than merely to differ.

Steps 2 and 3 are a decision, not a chore, and should not be started before
step 1 has produced a week of numbers.

**Status 2026-08-08:** step 1 (instrumentation) and step 2 (the
`UserPromptSubmit` hook, cross-project relevance, `scope`) are done and in
production. Step 3 — a fixture corpus of (task → lesson that should surface)
pairs, and any change to ranking — is **blocked on data by choice**: come back
once `brain_status` reports a counting window of 30 days.

### Phase 3 — `agent-worktrees`: the paths deliberately not covered yet ✅ done 2026-08-08

- **The herdr integration.** Every herdr call is currently skipped by
  `AGENT_WORKTREES_NO_HERDR=1`, because exercising it rearranges the panes of
  whoever is working right now. Needs a fake `herdr` on `PATH` that records its
  argv and returns canned JSON — then `adopt_current_pane` (move before close,
  the rename, the `jq`-absent and `HERDR_PANE_ID`-absent fallbacks) and
  `herdr_forget` become testable without a live server.
- **`rehearse` against a real conflict.** Currently only the clean case runs.
  Needs a fixture whose base and session touch the same line.
- **`where`** arithmetic: ahead/behind counts after the base moves.
- **`clean`** against a session whose base was deleted from the remote.
- **`install.sh` itself** — into a throwaway `HOME`: both rc files, the
  already-installed path, the stale-pasted-function warning, the missing-`PATH`
  warning.

### Phase 4 — `brain-mcp`: the MCP surface, beyond the happy path ✅ done 2026-08-08

`src/` has 39 tests and they pass; this is hardening, not repair.

- Concurrency: two agents writing while a third reads (SQLite locking).
- `brain_export` / `brain_import` round-trip fidelity at size, with unicode and
  embedded newlines — lessons here are Polish prose with code blocks in them.
- Embeddings degradation, extended: endpoint slow rather than dead; partial
  reindex resumed.
- Archive/forget semantics: FTS rows and embeddings both gone.

---

## What this plan deliberately does not do

- **No coverage-percentage target.** It would have been green on the day both
  projects were broken.
- **No test framework added to `agent-worktrees`.** Plain bash, for the same
  reason the tool refuses to depend on `gum` or `fzf`.
- **No rewrite of the hooks before they are tested.** Phase 2 changes retrieval;
  Phase 1 must come first, so the change can be shown to be safe.
