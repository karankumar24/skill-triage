# Security

## Reporting a vulnerability

Email `karan.kumar24@nixorcollege.edu.pk` with `[skill-triage security]` in the subject. Please do not file a public issue for vulnerabilities; give me a chance to fix it first.

If you do not get a reply within 7 days, open a public issue tagging `@karankumar24`.

## What this skill does with your data

skill-triage runs locally. The bundled scanner reads SKILL.md frontmatter from your own machine and writes a per-UID cache under `${XDG_CACHE_HOME:-$HOME/.cache}/skill-triage/`. The cache contains only skill names, source labels, and skill descriptions — nothing user-specific.

Two paths involve external network calls:

### Discovery fallback (`WebFetch`, `WebSearch`)

When the local scanner returns no skills matching your task, skill-triage falls back to web discovery. Before any network call, the model is instructed to scrub the task to safe keywords:

- Drop emails, names, IDs, file paths, URLs, hostnames
- Drop secrets and any quoted user data
- Send only generic terms

For example, a task like `"delete the user with email foo@bar.com from prod"` is scrubbed to keywords like `database delete row` before it reaches `WebSearch`.

What is sent off-machine:

- Allow-listed `WebFetch` calls to `raw.githubusercontent.com` for the curated registry READMEs (`anthropics/skills`, `travisvn/awesome-claude-skills`, `hesreallyhim/awesome-claude-code`)
- Verification `WebFetch` calls to candidate skills' `SKILL.md` URLs on the same host
- A `WebSearch` query of scrubbed keywords (last resort, only if the allow-list yields nothing)

What is not sent:

- The raw task text
- Project files, source code, or git history
- Filenames or paths from your machine

### Install commands suggested by discovery

Discovery output includes a copy-paste install command that runs `git clone --depth 1` and `cp -r` against a third-party repo you choose to install. Discovery only suggests; it does not run the install for you. Review the upstream repo's `SKILL.md` and any bundled scripts before running anything.

## Reducing the surface

If you do not want any web calls:

- Disable `WebFetch` and `WebSearch` for sessions where skill-triage runs. The skill detects tool-unavailability and falls through to a plain `proceed directly` verdict.
- Or remove the "Step 4c — Discovery fallback" section from your local copy of `SKILL.md`.

## Threat model

Out of scope: anyone with shell access to your account on the same machine. The cache is per-UID under your home directory, but a co-resident attacker with the same UID can read it.

In scope: a malicious skill (third-party or pre-installed) cannot influence skill-triage's recommendation beyond what the YAML frontmatter parser reads, which is `name` and `description`. Both are sanitized before printing (newlines stripped, pipe characters replaced with `/`, output capped at 280 chars).
