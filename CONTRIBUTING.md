# Contributing

Thanks for considering a contribution. skill-triage is small on purpose — the goal is to prevent skill thrash, not to grow into a meta-framework.

## Before you open a PR

- Run the scanner end-to-end on your machine: `bash skills/skill-triage/scripts/scan-skills.sh --refresh`. Confirm output looks sane.
- Lint the shell script: `shellcheck skills/skill-triage/scripts/scan-skills.sh`. Address findings.
- Re-read the SKILL.md from the top after your edit. If a new section creates a contradiction with another, fix it now, not later.

## What I will likely accept

- Bug fixes in the scanner with a one-line repro in the PR description.
- Improvements to the YAML frontmatter parser that handle a real SKILL.md the current parser misreads. Please attach the SKILL.md.
- Better example prompts in `examples/examples.json`. Generic, reproducible, no project-specific names.
- Tightening of the discovery fallback (more allow-listed sources, better URL verification, better scrubbing of task keywords before web calls).

## What I will likely reject

- Additions to the SKILL.md that bloat the prompt without addressing a concrete failure. Token bloat is a regression.
- New features that introduce a dependency beyond `bash`, `awk`, `find`, `mktemp`, `git`. Keeping the surface small is a feature.
- Changes that soften the 4-tier complexity rubric or the skill budget cap. Both are load-bearing — soften them only with a concrete failure mode they make worse.
- Auto-install behavior in the discovery fallback. Discovery suggests; the user installs.

## Commit and PR style

- Commit messages: imperative present tense, descriptive subject under 72 chars. Body explains *why* if not obvious.
- One concern per PR. Smaller PRs land faster.
- No AI-generated commit messages or PR descriptions. Write in your own voice.

## Bug reports

Please include:

- The exact task wording you gave to skill-triage.
- The scanner output (`bash skills/skill-triage/scripts/scan-skills.sh`).
- What skill-triage recommended, and what you expected instead.
- macOS or Linux, and the bash version.

## Code of conduct

Be kind. Assume good faith. Disagreements are expected; rudeness is not.
