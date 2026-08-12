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

## 2026-08-12 — the third caller, which I did not look at

**Done.** `rehearse` had the same `|| echo 0` as `where`, and `verify` gained a
check that does not care which command you were about to run. 60 → 62 scenarios.

**The finding, and it is about me rather than the code.** `base_of` has three
callers. `clean` guarded the failure. `where` did not, and I fixed it an hour
earlier — writing in the entry two below that *"a hazard documented where it was
first met does not follow the function to its next caller."* Then I pushed
without looking at the third caller.

`rehearse` is also the worst of the three. `where` fell silent; `rehearse`
printed, in green, **"up to date with origin/ — nothing to pull"** — from the
command whose entire purpose is answering "can I safely pull?". Silence can be
misread; this was an answer, and it was wrong, and it was reassuring.

**Done properly this time, at brain-mcp's suggestion.** They fixed their
equivalent at three levels and named the middle one as the part that actually
travels: a check in `doctor` that works *regardless of which path created the
problem, including paths that do not exist yet*. So `verify` now checks that every
session's base still resolves — by state, not by call site. However the session
was made, whatever command is added later, that check holds.

**Proven.** Both scenarios fail against `912e05b`: `[up to date with] should NOT
be there`, and the missing `0 of 1`.

**Found, twice, in the tests themselves.** The first `rehearse` scenario went red
against **correct** code: it asserted the absence of "nothing to pull", and the
new error message quotes that phrase to explain what it is not saying. The
assertion now targets the green sentence that was the actual lie. Second time
today a check has caught a defect in itself — the shellcheck scenario broke on
its own comment two entries up. Both were cheap. Neither was free, and both were
found only by watching the thing fail rather than by watching it pass.

**Next.** Nothing new.

---

## 2026-08-12 — the linter now runs inside the suite, and caught itself

**Done.** A scenario runs shellcheck with exactly CI's flags, skipped rather than
failed when it is not installed, and saying so out loud when the local version is
not the 0.11.0 CI pins. 59 → 60 scenarios.

**Why.** The pipeline went red on SC2034 in `test/run.sh` minutes after a green
local run. No version gap this time — the linter simply was not run: the local
check after editing a test was `bash -n` and the suite, and shellcheck lives in a
separate command nobody has a reason to type after touching a test file. Twice in
one day the gate deciding what reaches `main` was stricter than anything on this
machine; once from a version gap, once from not being invoked. Resolving to
remember it is the answer that already failed, so it moved into the command that
does get run.

**Proven, by itself, immediately.** The new scenario failed on the commit that
introduced it — on its own comment. A line beginning `# shellcheck ...` is a
**directive**, not a comment, so the paragraph explaining why the check skips when
shellcheck is absent broke the parse of the whole file. Reworded, plus a sweep for
any other comment line starting with that word. A guard whose first red is a
defect in itself is the cheapest possible proof that it runs.

**Next.** Nothing new.

---

## 2026-08-12 — applying #368 to our own numbers, and finding two

**Done.** brain-mcp synthesised the day's corrections into **#368**: in four
incidents the number was computed correctly and what was false was **the default
scope the reader supplied** — that the scan covered everything, that the counter
had always run, that blocked meant lost. Its test is one question: *does this
number measure the world, or the instrument?*

Asked of every number this tool prints, it found two. 57 → 59 scenarios.

- **`where` answered "0" when it meant "I could not count."** `rev-list` failing
  became zero through a `|| echo 0`, and both lines print only when non-zero — so
  the failure came out as **silence**. It now says so and stops.
- **`verify` reported "sessions with linked memory: 3" with no denominator**, in
  green. Three of three is working; three of nine is six agents starting with an
  empty head, which is the failure the feature exists to prevent. It reports
  `N of M`, names the sessions that are unlinked, and counts a shortfall as a
  problem instead of ending with "All checks passed".

**Proven.** Both scenarios fail against `df46937`. The `where` output there is the
argument by itself: a session with a real commit in it prints
`Session: kamar-adrift · branch: session/adrift · base: origin/` — note the empty
base — **and nothing else**. Nothing else is what "you are in sync" looks like.

**Found.** `clean` already made this distinction: *"skipping (cannot count commits
against $base)"*, with a comment in `base_of` explaining that `|| echo 0` would
make a session full of work look untouched and get it deleted. The trap was
understood, written down, and guarded — **in one of the two callers.** A hazard
that is documented where it was first met does not follow the function to its
next caller; only a check that runs does. That is the same argument as the guard
two entries down, arrived at from the opposite direction: there, a pattern was
turned into a grep because a journal entry only describes its own occurrence.

**Next.** Nothing new.

---

## 2026-08-12 — the entry below overstates #130, and I am the one who amplified it

**Done.** Nothing in the code. The entry below describes brain-mcp's **#130** as
"five months of a shop without those payment methods". That is wrong, it is in
this repository's record and in the message of commit `300d9ae`, and a commit
message cannot be corrected — so it is corrected here.

**Corrected, and verified against the lesson itself rather than taken on trust.**
#130 says why nobody noticed, and the reason is also the limit of the damage:
`update_order_review` — the AJAX call every checkout makes — is **not** covered by
the optimiser's per-action map, so it loads all plugins and re-renders the payment
fragment **with** PayU and P24. Normal checkout therefore healed itself the moment
a customer typed their address, and a second mu-plugin hides the methods until
`updated_checkout`, so there was not even a flicker to see. **The order-pay page
has no `update_order_review`** — so the permanent loss was confined to customers
returning to retry payment on an existing order.

Real, and `critical` in #130 is deserved. Not months of lost revenue, and it must
not be put to Marcin that way.

**Found — two failures, and only one of them is theirs.** brain-mcp read #130's
header, saw the date range, and wrote it up with a price. Their own base holds
**#309**, which warns about exactly this: a report said "232 blocked attempts",
which reads as 232 lost orders, while the real loss was **18** because 92.5%
ordered within the hour — and its rule is *always count the RECOVERY, not the
blocking events*. They walked into it while writing a lesson about reading
evidence, with the counter-lesson one query away.

Mine is the second failure and it is not smaller. I took a secondhand summary,
did not read the source, and **promoted it to the headline of my report** — "the
most important thing from these two days", with a budget argument attached. The
peer supplied a claim; I am the one who raised its rank without checking it. A
relay that adds emphasis has taken responsibility for the content, and this is the
second time today the useful outcome came from somebody measuring instead of
agreeing. The first time I was the one corrected. The direction is not the point.

**Open, not acted on.** Sizing the real cost needs a production query — orders
from `order-pay` in the February–July window against after 10 July, split by
payment method and status. That is kamar's production, not this repository's
business, and neither session is doing it off its own bat. It goes to Marcin as a
decision.

**Next.** Nothing new.

---

## 2026-08-12 — auditing our own exclusion list

**Done.** The three suppressed shellcheck codes in CI now each carry what they
cover, where they currently fire, and the date somebody checked. No code change.

**Proven.** Each was measured by removing it and reading what appeared, not
assumed: SC2001 at `agent-worktrees.sh:980,:1173` (indenting a multi-line string
with `sed`), SC2016 at `install.sh:34` and `test/run.sh:1110,:1122` (strings that
must stay literal — the PATH line you are meant to paste), SC3043 at `awt.sh:41`
(the deliberate `local`). All three kept, all three justified.

**Found.** Prompted by brain-mcp **#367**, and by the evidence they went looking
for before recording it — **#130**: an allowlist of plugin filenames in KAMAR's
checkout optimiser, with the names wrong, silently removing PayU and Przelewy24
from `/koszyk/` and `/zamowienie/` **from 22 February to 10 July**. Five months of
a shop without those payment methods, and not one error in the logs.

Their recognition test is the part worth keeping: **do not count the entries in an
exclusion list — check the date of the last REMOVAL from it.** A list nothing has
ever left is not a list of exceptions; it is a list of things the gate no longer
watches. Ours had never been audited at all, which is why it now carries dates
rather than a count.

**Next.** Nothing new.

---

## 2026-08-12 — a correction, measured on the other side

**Done.** Nothing in the code. This entry exists because the one below it states
a cause that turned out to be wrong, and the journal is appended to, never
rewritten.

**Corrected.** That entry says of the 148-character footer which collided two
unrelated lessons at similarity 0.999: *"That footer is ours."* The brain-mcp
session measured it rather than accepting the apology, and the accounting is
different:

- Their schema **already has a `source` field**, filled by 93% of lessons. The
  provenance was supplied once, in the right place. It was **copied into
  `content` as well** on the receiving side, and that duplicate is what the
  similarity measure read.
- The scale was two passages out of 1276. Every short passage (<250 chars) in the
  base was checked for a twin above 0.92; there were exactly two, both this
  footer. The other 109 have no twin. Real mechanism, no systemic problem.
- Fixed there: footers stripped from #363, #364 and #365, passages and vectors
  rebuilt, `source` untouched. Twin passages now zero.

**So the transferable rule is narrower and more useful than the one recorded
below.** Not "provenance does not belong in prose" — provenance belongs in a
field *and must not be duplicated into the indexed body*. The duplicate gave the
reader nothing and cost the measure everything. Anything written to be matched
later — a lesson, a ticket, a document destined for a vector index — carries the
same hazard, and the ratio measured here is the argument: **0.999 on the
boilerplate against 0.699 on the substance.** Recorded there as **#366**.

**Found.** An apology accepted without measurement would have left both sides
believing something false, and the false version is the one that generalises
badly: it would have discouraged sending provenance at all. Being corrected by
somebody who counted is worth more than being agreed with.

**Next.** Nothing new.

---

## 2026-08-12 — the pattern, made executable

**Done.** A scenario that greps the three shipped scripts for `| head` and
`| grep -q` outside comments and fails on any hit. The last live instance —
`herdr --version | head -1` in `verify` — now goes through `first_line`, so the
count the guard defends is zero rather than a list of exceptions. Also: CI pins
shellcheck to one version (`d9a393f`), because apt shipped 0.9.0 and brew 0.11.0
and the two disagreed about SC2015 — the Linux job went red on a line that
passed on macOS and on the machine that wrote it. 56 → 57 scenarios.

**Proven.** Reintroducing `printf '%s\n' "$all" | head -1` in `default_base`
turns the guard red with `agent-worktrees.sh: 308:` and the offending line. That
is the exact regression: this is the function whose `head -1` meant
`new <name>` did not work in ANY repository, for a release.

**Found.** This repository has paid for one trap three times with three different
symptoms: the script dying in silence (`default_base`), a value printed and the
status failing anyway (`config`, which downgraded sessions to a shell with no
agent), and the one that never happened here only because it was written the long
way — a condition returning the OPPOSITE of the truth, since inside `if` a
SIGPIPE'd success reads as failure. Three journal entries would have described
three occurrences. One grep finds the fourth.

Reported to brain-mcp, where it became **#365** with `repeats: 258` — the first
use of a `repeats` field they added in response, after their semantic duplicate
detector merged **#363 and #364** at similarity 0.999 on an identical 148-character
provenance footer. **That footer is ours**: both lessons were sent from here with
the same "source: session agent-worktrees @ <sha>, journal entry <date>" line, so
two unrelated traps looked like one lesson. Provenance belongs in a field, not in
prose that a similarity measure will read as content — worth remembering the next
time anything is written to be matched later.

**Next.** Nothing new.

---

## 2026-08-12 — a guard suggested by another repository's suite

**Done.** The suite now runs under a throwaway `HOME` of its own
(`$TMP/home-nobody-should-write-to`) and a final scenario asserts nothing was
written to it. 55 → 56 scenarios. The `set -e` and SIGPIPE findings went to the
brain-mcp session directly rather than through Marcin; they came back as **#363**
and **#364**, both `scope=global`, and sent two of their own — this is the first
one acted on.

**Proven.** Twice, because the first proof failed and that was the useful part.

Dropping `HOME` from `awt_run` — the obvious break — did **not** trip the new
guard. `t_memory_symlink` failed instead, with "no symlink for the session". The
guard looked active and was not: `link_memory` writes only when
`~/.claude/projects/<key of the main repo>` already exists, and in a throwaway
home it never does, so a forgotten HOME there produces a *missing* symlink rather
than a stray one.

Dropping `HOME` from `install_into` did trip it, listing six paths under the
canary — `.local/bin/agent-worktrees`, `.local/share/agent-worktrees/awt.sh` and
their parents. That is the destructive path: without the canary those are
symlinks into the real `~/.local/bin`, plus a line appended to a real `.zshrc`.

Both halves are covered; only one of them from this scenario. The comment says so
explicitly, with what was measured, rather than implying the guard covers
everything under `$HOME`.

**Found.** A guard nobody has watched go red is indistinguishable from the bug it
guards against — which is the same shape as **#363** (`set -e` inactive inside
`$( )`) recorded hours earlier. Writing the scenario and seeing it pass proved
nothing; breaking two paths and finding that only one of them lit up is what
established its scope. The first break failing to trip it was worth more than the
second break tripping it.

**Received from brain-mcp, not yet acted on.** A measurement probe that lies:
they swept ranking parameters while a stale cached module pointed at a deleted
directory, so every configuration but the first scored 0%. They caught it by a
monotonic invariant — loosening a filter cannot *reduce* recall — so the number
was impossible rather than merely wrong. Nothing here compares variants today; if
a harness ever does, it needs one such invariant as a check on the measurement
itself.

**Next.** Nothing new here.

---

## 2026-08-11 — naming, the base question, and a hole in `set -e`

**Done.** Sessions are `<prefix>-<name>` — `kamar-finanse`, not
`kamar-base-session-finanse`. The prefix is the repository's directory name
minus a trailing `-base`/`-main`/`-repo`/`-work`, overridable with `prefix =`.
`new <name>` now asks which branch to cut from when there is a human present,
reusing the survey's `ask_base` rather than a second copy of it. 46 → 55
scenarios.

Three things had to change with it, and none of them were on the list:

- **`clean` stopped trusting directory names.** Its guard was
  `basename == "$PREFIX-"*`, which exists because an early version deleted other
  people's worktrees. With the prefix shortened to `kamar`, a hand-made
  `kamar-hotfix` passes that test. It now asks `is_session_branch` — `session/*`
  or a `branch.<name>.awtBase` key, which only this tool writes. Renaming a
  session no longer hides it either.
- **A neighbour is no longer entered.** `awt new checkout` beside `kamar-base`
  aims at `kamar-checkout`; the old code said "entering the existing one" and
  handed the path back, so the wrapper would have started an agent in an
  unrelated clone. `is_worktree_of_ours` refuses instead.
- **`list` stopped matching cwds by name prefix**, which with `kamar` would have
  claimed a different clone as one of this repository's working directories.

**Proven.** 8 of the 9 new scenarios fail against the previous commit —
`want [kamar-finanse], got [kamar-base-session-finanse]`, `want [1], got [0]`
for both the collision and the end-of-input case, `hotfix/only` where
`session/only` was wanted. The ninth,
`t_clean_ignores_a_lookalike`, passes against both **and that is the point**: it
pins a safety property that the old code got from a long prefix and the new code
gets from provenance. Had the prefix been shortened without the second change,
that scenario is the one that would have caught it.

**Found — the big one. `set -e` does not reach inside `$( )`.** bash inherits
errexit into a command-substitution subshell only under
`shopt -s inherit_errexit`, which does not exist in the 3.2 macOS ships, so this
tool can never rely on it. `cmd_new` runs inside `dir="$(cmd_new ...)"`.
Therefore **every failure inside `cmd_new`, including a bare `exit 1`, is
demoted to "that command returned non-zero" and the function carries on.**

Answering the new base question with end-of-input printed *"No input — the
survey cannot be answered. Nothing was created."* and then created the session
anyway, off whichever branch `default_base` liked, and exited 0. Reduced to
fifteen lines:

```bash
set -euo pipefail
inner() { exit 1; }
mid()   { local v; v="$(inner)"; echo "MID CONTINUED"; }
mid                 # -> exits 1, as expected
out="$(mid)"        # -> prints MID CONTINUED, exit 0
```

The same function, the same failure, and whether the script stops depends
entirely on how the caller was written. Everything in `cmd_new` that must stop
the work now says `|| exit 1` out loud. This is worth carrying beyond this
repository: it makes `set -e` useless as a safety net in exactly the place a
shell script is most likely to put its real logic.

**Also found.** The survey previewed `session/<name>` on its confirmation screen
while `cmd_new` went on to create `hotfix/<name>` — two copies of one rule, in
the one place the user is asked to approve exactly that. `branch_for` decides
once now, and a single-base repository gets a plain session rather than a hotfix
nobody chose.

**Next.** Nothing new here.

---

## 2026-08-11 — the same trap, one function further along

**Done.** `config()` ended in `... | head -1 | grep .`, which is the SIGPIPE +
`pipefail` trap that made `new <name>` fail in every repository — the one
`default_base` was rewritten for. It survived there because the failure mode is
different and worse: the pipeline prints the value and *then* returns non-zero,
so `config agent 2>/dev/null || echo claude` answers `claude\nclaude`. A
two-line agent name is not on `PATH`, so `session_agent` quietly downgrades the
session to a plain shell — a session with no agent in it, reported as success.
Replaced with `first_line()`, a parameter expansion with no pipe and no second
process; `default_base` and `herdr_forget` now use it too, so no `head -1`
remains on any path that matters. 45 → 46 scenarios.

**Proven.** `t_config_first_line_has_no_pipe` against the previous commit:
`want [claude], got [plain shell]`.

**Found.** Whether this fires depends on whether the producer's output fits in
the 64 KB pipe buffer, which is why a plausible config file never triggers it
and the test fixture has to be absurd (5 000 duplicate keys) to force it. That
is the whole reason the class keeps coming back: it works by luck until the
input grows, and the luck is invisible in review. It was found this time by
grepping for the shape — `| head`, `| grep`, `| jq` under `set -e` — rather than
by anything failing.

**Next.** Nothing new. The ranking decision in
[`NEXT-SESSION.md`](NEXT-SESSION.md) is still the only open item.

---

## 2026-08-08 — usability — the fast path that stopped one command short

**Done.** Five changes, all from one real attempt to start a session called
`finanse` in `kamar` that took seven commands:

- `agent-worktrees.sh` — `new` now answers the wrapper with the same reply the
  survey does (directory, agent, arguments), so `awt new <name>` leaves you
  standing in the session with the agent running. Without the wrapper it still
  prints the path and nothing else; that is what scripts and CI read.
- `awt.sh` — `new` joins `start` in the protocol branch of the `case`.
- `agent-worktrees.sh` — an unknown word is an error: stderr, exit 2, and the
  suggestion `agent-worktrees new <word>` when it looks like a session name.
  `help`/`-h`/`--help` keeps stdout and exit 0, because that one was asked for.
- `agent-worktrees.sh` — outside a repository, the refusal lists the
  repositories directly below you instead of telling you to go find one.
- `agent-worktrees.sh` — `link_memory` reports instead of printing, so the
  memory line appears under its heading rather than above it.

37 → 45 scenarios. shellcheck clean, suite green under bash 5 and the 3.2 that
macOS ships.

**Proven.** The new suite run against `HEAD` fails 7 of the 8 assertions it
adds: exit 0 where 2 is wanted (three scenarios), one protocol line where two
are wanted, a stale wrapper not refused, no repository named, and the memory
line above its heading. The eighth — `help` on stdout with exit 0 — passes
against both, on purpose: it is a **regression guard**, pinning behaviour that
used to be an accident of the catch-all branch and is now deliberate. So is
`new` without the wrapper still printing exactly one line.

**Found.** Three things, none in the plan.

1. **The catch-all branch was the bug.** `*) cat <<HELP` printed 20 lines to
   **stdout** and exited **0**. So `awt finanse` was, to the shell and to any
   script, a success that produced help text — and to a human, a wall with no
   sentence in it saying "no such command". The single most natural thing to
   type had the least informative answer in the tool.

2. **A fast path that stops short is slower than the slow path.** `new` was
   documented as "no questions asked" and it created the directory correctly —
   but the survey creates it *and* enters it *and* starts the agent, so the
   "fast" path cost two extra hand-typed commands, one of them a directory name
   derived by hand from a printed path (`../kamar-base-session-finanse`). The
   asymmetry was invisible from inside either code path; it is only visible in a
   transcript of somebody using both. A smaller symptom of the same gap: on a
   second `new` with the same name the tool printed "Worktree already exists —
   **entering** the existing one" and then did not enter it. The sentence was
   written for a version of `new` that had never existed; it is true now.

3. **`set -e` and `link_memory` were one `ln` away from a silent stop.** The old
   body ended in `ln -s ... && info ...`; had the symlink ever failed, the
   function would have returned 1 as the last command of a simple call in
   `cmd_new`, ending the script *after* the worktree existed and *before* it was
   announced. Rewriting it to return a status on purpose removed the trap along
   with the ordering problem.

**Next.** Nothing here. The open item is still the ranking decision in
[`NEXT-SESSION.md`](NEXT-SESSION.md), still blocked on 30 days of data.

---

## 2026-08-08 — closing pass — the fix that had not reached the machine it was written on

**Done.** Protocol versioning, an end-of-input guard, and a watchdog in the
suite. 34 → 37 scenarios. Merged to `main`, CI green. The author's own `.zshrc`
migrated from a pasted `awt()` to the sourced file, and the whole loop verified
through real zsh: survey → session → agent running in the session directory →
shell left there.

**Proven.** Reverting the version check ran the survey instead of refusing;
reverting `read_line`'s EOF handling reported *"spun on end of input"* — caught
by the watchdog rather than hanging the run.

**Found — and this is the one worth keeping.**

`awt` had been broken on this machine all day. The morning's change moved the
reply from three tab-separated fields to one field per line; the shell still held
a copy of the old function pasted in before there was a file to source. It split
on tabs, found none, handed `cd` all three lines and returned 1. Silence.

Three things made it survive:

1. **Everything except `awt` kept working.** No other subcommand goes through the
   function, so `awt list`, `awt where` and `agent-worktrees new` were all fine.
   A failure with a small blast radius is harder to place, not easier.
2. **The README warning was written by the person who then hit it.** Knowing the
   hazard does not migrate anybody's shell, including your own. A warning is not
   a mechanism.
3. **Nothing checked.** Two components shipped separately, agreed a format, and
   had no way to notice they disagreed.

So: **a protocol between separately-shipped components needs a version, or the
mismatch is silent.** The wrapper now announces which one it speaks and the tool
refuses a mismatch with a sentence — checked before the survey, because asking
for a base, a name and an agent and only then admitting the answer cannot be
delivered is the rudest possible ordering.

Two more, smaller but general:

- **Removing a guard should make a test fail, not hang.** It happened twice here,
  and the second time it left a deliberately broken file on disk while I chased
  the hang. `timeout(1)` is absent on macOS; `with_timeout` is the portable
  background-poll-kill version. A suite that hangs is a suite people stop running.
- **EOF is an answer.** `read` fails at end of input, the old `read_line` turned
  that into an empty string, and `ask_name` rejected it and asked again for ever.
  Any pipeline or CI job running the survey hit it. The confirmation prompt still
  treats EOF as consent, so `yes "" | awt` matches a human pressing Enter.

**Next.** Unchanged: Phase 2 step 3, blocked on 30 days of `shown_count`.

---

## 2026-08-08 — Phase 4 — the questions the happy path never asks

**Done.** `tests/hardening.test.ts` (8 scenarios) and a Retrieval section in
`brain_status`. Merged to `prod`; CI green on Node 20 and 22. Totals now: 49
server tests, 45 hook tests, 34 in `agent-worktrees`.

- **Concurrency** — two connections writing interleaved, 40 rows, none lost, and
  all 40 present in the FTS index. A lesson that exists and cannot be found is
  worse than one that does not exist. A read-only connection must see committed
  writes, not a stale snapshot.
- **Archive semantics both ways** — `brain_forget` must remove the FTS row, not
  just the lesson; `brain_restore` must put it back; and restore *without*
  `confirm: true` must change nothing.
- **Export fidelity against what the base actually holds** — Polish prose with a
  fenced bash block, CRLF, a trailing backslash, the export format's own
  delimiters. Run **twice**, because a round-trip that normalises something on
  the first pass looks lossless from the second onwards. Plus a truncated export
  file, which must import nothing rather than half a lesson.
- **Slow embeddings**, not merely dead — a call that waits is indistinguishable
  from one that hung.

**Proven.** Removing the `lessons_ad` trigger failed the archive scenario;
removing the counting-window guard failed the status scenario.

**Found.**
- `brain_restore` looked broken and was not: it is a two-step with `confirm`,
  and the test called it without. The fix was to assert **both** steps — the
  no-op without confirm is now covered, which it was not before. A safety gate
  that quietly stopped gating would otherwise look exactly like a passing test.
- `brain_status` initially reported *"120 lessons older than 30 days and never
  surfaced"* on the day the counters were added — true of the whole base by
  construction, and reading like a finding about the lessons when it was a fact
  about the clock. The window is measured from the first recorded retrieval now,
  and the number is withheld until it means something. **Generalises: a metric
  introduced today cannot describe yesterday, and presenting it as though it can
  is worse than not measuring.**

**Next.** Only Phase 2 step 3 remains, and it is deliberately blocked: read
`shown_count` after a week of real use before touching ranking. Everything else
in the plan is done.

---

## 2026-08-08 — Phase 2 (cont.) — a false positive caught by using the thing

**Done.**
- `incident_watch` no longer reports the *creation* of a backup as an undo. The
  check is positional now — is the `.bak` a source of the copy or its
  destination — instead of a regex proxy. Four tests, both directions, unit and
  end to end.
- `brain_learn` accepts `scope: "global"`, so a lesson about a tool rather than a
  project can say so. The column existed since this morning and nothing wrote it.
- `initDB` migration of a pre-existing database is tested: existing rows land on
  `shown_count = 0` and `scope = 'project'`, not NULL.
- Both PRs merged to `prod`, CI green on Node 20 and 22. Live database migrated
  with all 297 lessons intact.

**Proven.** The old regex was restored and
`test_end_to_end_a_backup_does_not_prompt` failed.

**Found.** Installing the new hooks tripped the old one:

```
cp ~/.claude/settings.json /tmp/settings.json.bak-$(date +%s) && ls ...
```

was reported as *"restored from a backup"*. Nothing was restored — a backup was
being taken before touching a live config, which is the most careful thing
anybody does, and the worst possible thing for a precision-first hook to scold.

It is the **second** time that same mistake shipped. The source comment records
the first: a regex matching a `.bak` anywhere, fixed by excluding one at the END
of the command. A timestamp suffix followed by `&&` walked straight through the
fix. Worth stating as a class, because it generalises well beyond this file:

> When the real question is **positional** — is this thing an input or an
> output? — a textual proxy like "is it last?" will keep almost working. Each
> counterexample looks like a one-off worth patching, and the patch buys another
> few weeks. Ask the real question instead.

**Verified end to end on the live system.** A session in `kamar` asking about a
silent `exit 141` now receives lesson #296 (filed under `agent-worktrees`),
#258 and #261 — from three different projects. The old digest would have shown
none of them: #296 is not in `kamar`'s twelve. `shown_count` is accumulating and
`updated_at` is untouched.

**Next.** Read `shown_count` in a week before touching ranking. Phase 4 remains.

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
