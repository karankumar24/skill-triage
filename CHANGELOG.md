# Changelog

All notable changes to skill-triage are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-05-09

Initial public release.

### Added
- `skills/skill-triage/SKILL.md` — meta-skill that triages installed Claude Code skills against a task and emits a structured routing plan.
- `scripts/scan-skills.sh` — frontmatter-only skill scanner with per-UID 10-minute cache. Emits `name|source|description` lines for every installed skill across personal, plugin, and project scopes.
- 4-tier complexity rubric: `simple` / `medium` / `complex` / `high-risk`. Risk flags surface destructive, secrets, prod, irreversible, and mass-edit operations.
- Per-tier skill budget (0-5 relevant skills) with one-skill-per-role enforcement.
- Discovery fallback for cold-start machines: privacy-scrubbed allow-list search across `anthropics/skills`, `travisvn/awesome-claude-skills`, `hesreallyhim/awesome-claude-code`, then verified `WebSearch`. Every candidate URL is fetched for an actual `SKILL.md` before suggestion. Capped at 3 results.
- `examples/examples.json` — illustrative test prompts.
- `SECURITY.md` — privacy model for the discovery fallback.
- `CONTRIBUTING.md` — contribution guide.
- Apache-2.0 license.
