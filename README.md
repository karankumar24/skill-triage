<div align="center">

<img src="docs/banner.png" alt="skill-triage" width="720">

# The skill that picks the skill

**Give it a task, and it tells Claude Code which of your installed skills to use, in what order, and when to stop and ask first.**

<a href="https://github.com/karankumar24/skill-triage/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/karankumar24/skill-triage/ci.yml?branch=main&style=flat-square&label=ci" alt="ci"></a>
<a href="#install"><img src="https://img.shields.io/badge/Claude_Code-skill-D97757?style=flat-square" alt="Claude Code skill"></a>
<a href="#install"><img src="https://img.shields.io/badge/bash-3.2%2B-4EAA25?style=flat-square" alt="bash 3.2+"></a>
<a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache_2.0-blue?style=flat-square" alt="Apache 2.0 license"></a>

</div>

---

With a lot of skills installed, it's easy for Claude to grab the first one that sounds right, or to chain four when one would do. skill-triage makes the call: one skill per job, a cap per task, and a stop before anything destructive.

You ask: *"the staging database has stale test rows in events, sessions, and audit_log. truncate all three so we can reseed clean."*

```markdown
## Routing plan

**Task:** TRUNCATE three tables on staging DB to reseed.
**Complexity:** high-risk
**Risk flags:** destructive, irreversible

**Relevant skills:**
- `careful` (wraps destructive commands with a confirmation gate)

**Avoid:**
- a generic plan-execute skill (bypasses the safety conversation)

**Recommended order:**
1. **pre:** verify staging is staging (not prod), confirm zero downstream readers
2. **impl:** `/careful` then issue `TRUNCATE events; TRUNCATE sessions; TRUNCATE audit_log;`

**Verdict:** stop and ask
```

Then Claude asks before touching anything: a dry run with row counts, go ahead after a backup, or stop. Skill names come from your machine, so `careful` stands in for whatever safety skill you have.

## How it picks

- It sorts the task into simple, medium, complex or high-risk, using the task itself, `git status` and the last five commits.
- A bundled scanner lists your installed skills (personal, plugin and project) from their frontmatter alone. Claude opens at most three of them in full.
- It keeps one skill per job (one planner, one reviewer) and caps the list by tier: none for simple, 1-2 for medium, 3-5 for complex, 1-2 for high-risk. Whatever it drops goes under **Avoid** with a reason.
- High-risk tasks always end in "stop and ask", even when a skill fits.
- When nothing installed fits, it checks three curated lists ([anthropics/skills](https://github.com/anthropics/skills), [awesome-claude-skills](https://github.com/travisvn/awesome-claude-skills), [awesome-claude-code](https://github.com/hesreallyhim/awesome-claude-code)), then a web search. It only suggests skills whose SKILL.md it could actually fetch, at most three, with how to install each. It suggests; you install.

Simple tasks get one line: no skill needed.

## Install

Needs bash and git. Copy the skill into your personal skills folder:

```bash
DIR=$(mktemp -d)
git clone --depth 1 https://github.com/karankumar24/skill-triage.git "$DIR"
mkdir -p ~/.claude/skills
cp -r "$DIR/skills/skill-triage" ~/.claude/skills/
rm -rf "$DIR"
```

For one project only, copy it into that repo's `.claude/skills/` instead. If Claude Code was open and `~/.claude/skills` is new, restart it once.

Check the scanner:

```bash
bash ~/.claude/skills/skill-triage/scripts/scan-skills.sh | head
```

It prints one line per installed skill, `name|source|description`. With no other skills installed, you'll only see skill-triage's own line.

## Usage

Claude can run it on its own before bigger tasks, since its description asks for that. To run it yourself:

```
/skill-triage add email verification to the signup flow
```

Skills kept somewhere else? Point the scanner at them with `SKILL_TRIAGE_EXTRA_ROOTS=~/.codex/skills:/other/dir`.

## Your data

- The scanner reads SKILL.md frontmatter on your machine and caches the list under `~/.cache/skill-triage/` (or `$XDG_CACHE_HOME`), readable only by you.
- It goes online only when no installed skill fits. Claude is told to send a few generic keywords, never your task text, file names or paths.
- Set `SKILL_TRIAGE_NO_DISCOVERY=1` to tell it to skip web lookups. For a hard stop, deny WebFetch and WebSearch in your Claude Code permissions. [SECURITY.md](SECURITY.md) has the details.

## Good to know

- It gives advice. It doesn't block tool calls, and "no, just do it" wins.
- It's a set of instructions, so Claude follows it the way it follows any prompt. That includes the keyword scrubbing before web calls.
- For the turn it runs, its `allowed-tools` line lets Claude use Bash, Read, WebFetch and WebSearch without asking. Deny rules in your settings still apply.
- The scanner reads YAML with a small awk parser. Normal SKILL.md files are fine; odd indentation in multi-line descriptions may not be.
- CI runs the scanner tests on Ubuntu, macOS (including the stock bash 3.2) and Alpine. Not tried on Windows.

## Contributing

Issues and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) says what fits, and `bash skills/skill-triage/scripts/__tests__/test_scanner.sh` runs the scanner tests. Apache 2.0 licensed.
