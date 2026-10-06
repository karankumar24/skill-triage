<div align="center">

<img src="docs/banner.png" alt="skill-triage" width="720">

# The skill that picks the skill

**Give it a task, and it tells Claude Code which of your installed skills to use, in what order, and when to stop and ask first.**

<a href="https://github.com/karankumar24/skill-triage/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/karankumar24/skill-triage/ci.yml?branch=main&style=flat-square&label=ci" alt="ci"></a>
<a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache_2.0-blue?style=flat-square" alt="Apache 2.0 license"></a>

</div>

---

With a lot of skills installed, Claude can grab the first one that sounds right, or stack several when one would do. skill-triage makes the call: the right skill for each job, and a stop before anything risky.

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

Then Claude asks before touching anything. Skill names come from your machine, so `careful` stands in for whatever safety skill you have.

## How it picks

- It sizes up the task, from simple to risky.
- It looks through the skills you have installed and keeps one per job.
- Risky tasks always end with Claude asking you first.
- If nothing you have fits, it suggests a few skills from well-known lists. It never installs anything itself.

## Install

Needs bash and git. Copy the skill into your personal skills folder:

```bash
DIR=$(mktemp -d)
git clone --depth 1 https://github.com/karankumar24/skill-triage.git "$DIR"
mkdir -p ~/.claude/skills
cp -r "$DIR/skills/skill-triage" ~/.claude/skills/
rm -rf "$DIR"
```

If Claude Code was open and `~/.claude/skills` is new, restart it once.

## Usage

Claude can run it on its own before bigger tasks. To run it yourself:

```
/skill-triage add email verification to the signup flow
```

## Your data

It reads your installed skills on your machine. It only goes online when nothing you have fits, and Claude is told to search with a few general words, not your task or file names. [SECURITY.md](SECURITY.md) has the details.

## Contributing

Issues and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) says what fits. Apache 2.0 licensed.
