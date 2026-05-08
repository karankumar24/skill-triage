# skill-triage

A meta-skill for [Claude Code](https://docs.claude.com/en/docs/claude-code) that triages your installed skills against a task and emits a routing plan: which skill to use, in what order, what to avoid, and whether to ask before doing anything destructive.

If you have ten or fifty or two hundred skills installed, you have probably hit this: Claude picks the first plausible-sounding skill instead of the right one, or chains four skills "for safety" when one would do, or skips the safety wrapper before a `DROP TABLE`. This skill is the cut.

## What it does

Given a task, `skill-triage` produces:

- A one-sentence restatement of the task
- A complexity tier: `simple` / `medium` / `complex` / `high-risk`
- Risk flags (destructive, secrets, prod, irreversible, mass edit)
- A short ranked list of relevant installed skills with one-line "why"s
- An "Avoid" list — skills that look relevant but are not, with reasons
- A recommended order across `pre` / `impl` / `post` phases
- A verdict: `proceed directly`, `proceed with skill(s)`, or `stop and ask`

Trivial tasks collapse to a one-line "no skill needed" and proceed directly. Destructive tasks always stop and ask, even when a skill matches.

**Cold start.** If you have no skills installed yet, or none of yours match the task, skill-triage falls back to web discovery. It searches a small allow-list of curated registries first (`anthropics/skills`, `travisvn/awesome-claude-skills`, `hesreallyhim/awesome-claude-code`), then a verified `WebSearch` if needed. Every candidate URL is verified to exist and to contain a `SKILL.md` before being suggested — no invented skill names. Output is up to 3 candidates with copy-paste install commands.

## Why it exists

Claude already auto-loads skill metadata at session start. The problem is not discovery — it's selection. With 100+ skills installed, the auto-trigger heuristics fire too eagerly: a task that needs one planning skill ends up running a planner, a designer, a reviewer, and a "ship" skill in sequence. That is not routing, it is thrash.

This skill enforces a **budget**: at most 0–5 relevant skills per task by tier, and one skill per role (one planner, one reviewer, one designer). Every contender that didn't make the cut is named under "Avoid" with a reason — so future-you doesn't reach for it ten minutes later.

## Install

Clone into your personal skills directory:

```bash
git clone https://github.com/karankumar24/skill-triage.git /tmp/skill-triage
mkdir -p ~/.claude/skills
cp -r /tmp/skill-triage/skills/skill-triage ~/.claude/skills/
chmod +x ~/.claude/skills/skill-triage/scripts/scan-skills.sh
```

Or as a project-scoped skill, drop the `skills/skill-triage` folder into your repo's `.claude/skills/` directory.

Verify the scanner runs:

```bash
bash ~/.claude/skills/skill-triage/scripts/scan-skills.sh | head
```

You should see one line per installed skill, pipe-delimited: `name|source|description`.

## Example output

User asks: *"the staging database has stale test rows in events, sessions, and audit_log. truncate all three so we can reseed clean."*

```markdown
## Routing plan

**Task:** TRUNCATE three tables on staging DB to reseed.
**Complexity:** high-risk
**Risk flags:** destructive, irreversible

**Relevant skills:**
- `careful` — wraps destructive commands with confirmation gate

**Avoid:**
- a generic plan-execute skill — bypasses the safety conversation

**Recommended order:**
1. **pre:** verify staging is staging (not prod), confirm zero downstream readers
2. **impl:** `/careful` then issue `TRUNCATE events; TRUNCATE sessions; TRUNCATE audit_log;`

**Verdict:** stop and ask
```

Claude then opens an `AskUserQuestion` with three concrete options (dry-run with row counts, proceed after backup, abort) before running anything.

## How it works

1. Reads the user's task, the project `CLAUDE.md` if loaded, and `git status` / `git log -5`. Nothing else at this stage.
2. Classifies complexity on a 4-tier rubric. Risk and complexity are orthogonal — a one-line `DROP TABLE` is `high-risk`, not `simple`.
3. Runs the bundled scanner (`scripts/scan-skills.sh`) which reads SKILL.md frontmatter from `~/.claude/skills/`, `~/.claude/plugins/cache/*/`, and `.claude/skills/`. Cached for 10 minutes.
4. Filters by keyword overlap, ranks 0–10 candidates, reads full SKILL.md only for the top 1–3 finalists. Resolves role conflicts.
5. Applies the skill budget. Cuts excess relevant skills to "Avoid" with reasons.
6. For high-risk tasks, gates with `AskUserQuestion`. Otherwise emits the plan and lets the caller execute.

The full algorithm and design rationale lives in [`skills/skill-triage/SKILL.md`](skills/skill-triage/SKILL.md).

## Limitations

- The scanner uses a small `awk` YAML parser. It handles the common cases (`description: ...`, `description: |`, `description: >`) but is naive on quoted strings, escaped colons, and pathological multi-line structures. Real-world SKILL.md files parse cleanly; adversarial input may not.
- Plugin discovery assumes the default `~/.claude/plugins/cache/<plugin>/` layout. Custom plugin install paths will not be picked up.
- Linux + macOS supported. Windows is untested.
- This skill is advisory. It does not enter plan mode, does not block tool calls, and does not override an explicit user override ("no, just do it directly").

## Contributing

Issues and PRs welcome. The skill is intentionally small and conservative — additions should justify their complexity. The 4-tier rubric and the skill budget are load-bearing; do not soften them without a concrete failure mode they make worse.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

## Related

- [Claude Code skills documentation](https://docs.claude.com/en/docs/claude-code/skills)
- [anthropics/skills](https://github.com/anthropics/skills) — the official skills repo and template
