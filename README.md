# skill-triage

A meta-skill for [Claude Code](https://docs.claude.com/en/docs/claude-code) that picks the right installed skill for a task. Given a task it returns one structured recommendation: which skill to use, in what order, what to skip, and whether to ask before doing anything destructive.

If you have a lot of Claude Code skills installed, you have probably hit this. Claude picks the first plausible-sounding skill instead of the right one. Or it chains four "for safety" when one would do. Or it skips the safety wrapper before a `DROP TABLE`. skill-triage is the part that picks.

## What it does

Given a task, `skill-triage` produces:

- A one-sentence restatement of the task
- A complexity tier: `simple` / `medium` / `complex` / `high-risk`
- Risk flags (destructive, secrets, prod, irreversible, mass edit)
- A short ranked list of relevant installed skills with one-line reasons
- An "Avoid" list, with a reason for each rejection
- A recommended order across `pre` / `impl` / `post` phases
- A verdict: `proceed directly`, `proceed with skill(s)`, or `stop and ask`

Trivial tasks collapse to a one-line "no skill needed". Destructive tasks always stop and ask, even when a skill matches.

**Cold start.** If you have no skills installed, or none match the task, skill-triage falls back to web discovery. It searches a small allow-list of curated registries first (`anthropics/skills`, `travisvn/awesome-claude-skills`, `hesreallyhim/awesome-claude-code`), then a verified `WebSearch` if needed. Every candidate URL is fetched and checked for an actual `SKILL.md` before being suggested. No invented skill names. Output caps at 3 candidates with a copy-paste install command.

Task keywords (not the raw task) are scrubbed before any web call — see [SECURITY.md](SECURITY.md).

## Why it exists

Claude already loads skill metadata at session start. The problem is not discovery — it is selection. With a hundred skills installed, the auto-trigger heuristics fire too eagerly. A task that needs one planner ends up running a planner, a designer, a reviewer, and a "ship" skill in sequence. Not routing. Thrash.

skill-triage enforces a budget: at most 0–5 relevant skills per task by tier, one skill per role (one planner, one reviewer, one designer). Every contender that did not make the cut is named under "Avoid" with a reason.

## Install

Personal skill (your own machine):

```bash
DIR=$(mktemp -d)
git clone --depth 1 https://github.com/karankumar24/skill-triage.git "$DIR"
mkdir -p ~/.claude/skills
cp -r "$DIR/skills/skill-triage" ~/.claude/skills/
rm -rf "$DIR"
```

Project skill (only people in this repo see it):

```bash
DIR=$(mktemp -d)
git clone --depth 1 https://github.com/karankumar24/skill-triage.git "$DIR"
mkdir -p .claude/skills
cp -r "$DIR/skills/skill-triage" .claude/skills/
rm -rf "$DIR"
```

Verify the scanner runs:

```bash
bash ~/.claude/skills/skill-triage/scripts/scan-skills.sh | head
```

You should see one line per installed skill: `name|source|description`. On a brand-new install with no other skills, this prints just the `skill-triage` line — that is expected.

## Example output

User asks: *"the staging database has stale test rows in events, sessions, and audit_log. truncate all three so we can reseed clean."*

```markdown
## Routing plan

**Task:** TRUNCATE three tables on staging DB to reseed.
**Complexity:** high-risk
**Risk flags:** destructive, irreversible

**Relevant skills:**
- `careful` — wraps destructive commands with a confirmation gate

**Avoid:**
- a generic plan-execute skill — bypasses the safety conversation

**Recommended order:**
1. **pre:** verify staging is staging (not prod), confirm zero downstream readers
2. **impl:** `/careful` then issue `TRUNCATE events; TRUNCATE sessions; TRUNCATE audit_log;`

**Verdict:** stop and ask
```

skill-triage then recommends Claude opens an `AskUserQuestion` with three concrete options (dry-run with row counts, proceed after backup, abort) before running anything. The skill is advisory — it does not block tool calls. The caller decides whether to honor the gate.

## How it works

1. Reads the task, the project `CLAUDE.md` if loaded, and `git status` / `git log -5` (skipped if not a git repo). Nothing else at this stage.
2. Classifies complexity on a 4-tier rubric. Risk and complexity are orthogonal — a one-line `DROP TABLE` is `high-risk`, not `simple`.
3. Runs the bundled scanner (`scripts/scan-skills.sh`) which reads SKILL.md frontmatter from `~/.claude/skills/`, `~/.claude/plugins/cache/*/`, and `.claude/skills/`. Cached for 10 minutes per-UID under `${XDG_CACHE_HOME:-$HOME/.cache}/skill-triage/`.
4. Filters by keyword overlap, ranks 0–10 candidates, reads full SKILL.md only for the top 1–3 finalists. Resolves role conflicts.
5. Applies the skill budget. Cuts excess relevant skills to "Avoid" with reasons.
6. If the local result is empty, runs the discovery fallback. Curated allow-list first, `WebSearch` after. Candidates are URL-verified before being shown. Task is scrubbed first.
7. For high-risk tasks, gates with `AskUserQuestion`. Otherwise emits the plan and lets the caller execute.

The full algorithm and design rationale live in [`skills/skill-triage/SKILL.md`](skills/skill-triage/SKILL.md).

## Limitations

- The scanner uses a small `awk` YAML parser. It handles the common cases (`description: ...`, `description: |`, `description: >`, the `|-`/`>-` chomp variants, single-quoted, double-quoted) but is naive on adversarial nesting and escapes. Real-world SKILL.md files parse cleanly.
- Plugin discovery assumes the default `~/.claude/plugins/cache/<plugin>/` layout. Custom plugin install paths will not be picked up.
- Linux + macOS supported. Windows is untested.
- skill-triage is advisory. It does not enter plan mode, does not block tool calls, and does not override an explicit user override ("no, just do it directly").

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Issues and PRs welcome. Additions should justify the complexity they add — the 4-tier rubric and the skill budget are load-bearing.

## Security

See [SECURITY.md](SECURITY.md). The discovery fallback sends scrubbed task keywords off-machine; the raw task does not leave the host.

## License

Apache License 2.0. See [LICENSE](LICENSE).

## Related

- [Claude Code skills documentation](https://docs.claude.com/en/docs/claude-code/skills)
- [anthropics/skills](https://github.com/anthropics/skills) — the official skills repo and template
