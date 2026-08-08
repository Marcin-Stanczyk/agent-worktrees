# Where to pick up

One decision is open, and it is open **on purpose**. Everything else in
[`TEST-COVERAGE-PLAN.md`](TEST-COVERAGE-PLAN.md) is done and merged; the history
is in [`TEST-COVERAGE-JOURNAL.md`](TEST-COVERAGE-JOURNAL.md), newest first.

## The open decision — Phase 2 step 3: ranking

On 2026-08-08 `brain-mcp` was measured and found very good at *capturing* lessons
and close to inert at *recalling* them: 6 of 297 lessons could ever be seen
outside their own project, ranking was by recency rather than relevance, and
nothing recorded that a lesson had ever been read.

Steps 1 and 2 shipped that day — instrumentation (`shown_count`,
`last_shown_at`, `scope`) and a `UserPromptSubmit` hook that searches the FTS5
index across every project. **Step 3, changing the ranking itself, was blocked
until 30 days of real data existed**, so a change could be shown to help rather
than merely to differ. A one-time reminder is scheduled for **2026-09-08, 09:00
Atlantic/Canary** — [routine `trig_01FJKvYToTUNNCt6i1S9WGdN`](https://claude.ai/code/routines/trig_01FJKvYToTUNNCt6i1S9WGdN).
It cannot read the database (it runs in the cloud, `data/` is gitignored); it
comments on issue #2 with these commands and criteria, and nothing more.

### Read the data first

```bash
cd ~/code/b/brain-mcp

# the human-readable version
node -e "const{initDB,createTools}=require('./dist/tools.js');\
const db=initDB('data/knowledge.db');\
createTools(db,'/tmp').find(t=>t.name==='brain_status').handler({})\
.then(r=>{console.log(r.content[0].text);db.close()})"

# how much of the base has ever been reached, and how wide the window is
sqlite3 -header -column data/knowledge.db "
  SELECT COUNT(*) AS total,
         SUM(shown_count > 0) AS surfaced,
         SUM(scope = 'global') AS global_scope,
         MIN(last_shown_at)   AS counting_since
  FROM lessons;"

# which lessons actually earn their place
sqlite3 -header data/knowledge.db "
  SELECT id, project, scope, shown_count,
         substr(replace(content, char(10), ' '), 1, 60) AS preview
  FROM lessons WHERE shown_count > 0
  ORDER BY shown_count DESC LIMIT 20;"

# did cross-project retrieval actually happen, or is it all local after all?
sqlite3 -header -column data/knowledge.db "
  SELECT project, COUNT(*) AS surfaced_lessons, SUM(shown_count) AS times
  FROM lessons WHERE shown_count > 0 GROUP BY project ORDER BY times DESC;"
```

### Then decide, against these criteria

- **`counting_since` less than 30 days old → stop and re-arm the reminder.** The
  window is the whole point. `brain_status` withholds its own stale-lesson figure
  for the same reason: a metric introduced today cannot describe yesterday.
- **Surfaced share very low (say under 10%)** → the corpus is bigger than what
  gets asked about. That is a *wording* problem before it is a ranking problem:
  look at whether lessons are phrased in the words somebody would type.
- **Retrieval almost entirely from the current project** → the cross-project
  boost is too weak, or too few lessons are marked `scope='global'`. Prefer
  marking tool-lessons global over raising the boost; the boost is a blunt
  instrument and `scope` is a statement of fact.
- **A handful of lessons dominate** → check they deserve it. A lesson that
  matches everything is a lesson worded too vaguely, not a good lesson.

### Before changing any ranking

Build the fixture corpus the plan asks for: pairs of *(task description → the
lesson that should surface)*. Without it, a ranking change can be shown to be
different and never shown to be better. Put it beside the hook tests in
`brain-mcp/tests/hooks/`.

## Not started, and deliberately so — a `PreToolUse` guard

Surfacing a lesson *before* a risky command rather than after is the most
promising remaining idea and the easiest to get wrong. `incident_watch` already
demonstrated the failure mode twice: it reported the *creation* of a backup as an
undo, and being scolded for the most careful thing anybody does is how a hook
earns being switched off. If you build it, make it silent by default and prove
its precision on real command history before wiring it in.

## Housekeeping

- Local `awt` is sourced from `~/.local/share/agent-worktrees/awt.sh`; the old
  pasted copy was removed on 2026-08-08 (backup: `~/.zshrc.bak-20260808-110827`).
- After pulling `agent-worktrees`, run `./install.sh` — it is idempotent and
  keeps the symlinks pointing at the checkout.
- After pulling `brain-mcp`, run `npm run build` and `npm run hooks:install`.
- Suites: `./test/run.sh` here; `npm run test:all` in `brain-mcp`.
