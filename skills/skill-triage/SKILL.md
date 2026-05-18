---
name: skill-triage
description: Pick the right Claude Code skill for a task. Ranks installed skills, emits a routing plan, and falls back to web discovery if nothing matches. Use before non-trivial tasks (3+ steps, architectural decisions, or destructive operations).
when_to_use: Before any 3+ step task, architectural decision, multi-skill chain, or destructive/irreversible operation. Skip for trivial one-step edits or pure lookups.
argument-hint: "[task-description]"
allowed-tools: Bash Read WebFetch WebSearch AskUserQuestion
license: Apache-2.0
---

# Skill Triage

Routing meta-skill. Decides how to approach a task. Prefers skills the user already has installed. When nothing matches, searches a short allow-list of curated registries (and, as a last resort, the open web with URL verification) to suggest skills the user could install. Never recommends an installed skill just because it exists.

## What this skill does

Given a task, produce a short, structured recommendation:

1. Restated task (one sentence)
2. Complexity tier (simple / medium / complex / high-risk)
3. Risk flags (destructive, secrets, prod, irreversible, mass edit)
4. Relevant installed skills (ranked, with one-line "why")
5. Skills to avoid (with reason — prevents misfires)
6. Recommended order, grouped by phase: **pre** (plan / brainstorm / research) → **impl** (build / fix) → **post** (review / test / docs / ship)
7. Suggested slash-command invocations
8. Verdict: **proceed directly** | **proceed with skill(s)** | **stop and ask**

When the answer is "no skill needed," collapse to a single line — do not pad the template with empty sections.

## When to invoke

**Always run before:**
- Any task with 3+ steps or cross-file work
- Any architectural decision
- Anything destructive (deletes, force-push, schema changes, migrations on prod, secret writes)
- Any task where multiple plausible skills exist (e.g., a `review` skill vs. a code-quality auditor vs. a security review)

**Skip for:**
- Trivial one-step edits ("rename this var", "add a console.log")
- Pure read/lookup ("what does X do", "find the config")
- The user is mid-flow inside another skill

**Heuristic:** if you can finish the task confidently in one tool call, skip. If you'd have to pick between approaches or workflows, run the triage.

**One-time-only per task.** Do not re-run on follow-up turns inside an existing skill flow — the routing is already decided.

## How to run it

### Step 1 — Read the task and project context (cheap)

Pull only what's already free or one shell call away:
- The user's task wording (verbatim — do not paraphrase before classifying)
- Project `CLAUDE.md` if loaded in context (already in system reminder)
- `git status` and `git log -5 --oneline` (one bash call each, parallel; skip if not a git repo)

Do **not** read source files, config, or other directories at this stage. Cheap context only.

### Step 2 — Classify complexity (4-tier rubric)

Treat complexity and risk as orthogonal. A task lands in the higher of the two tiers.

| Tier | Signals |
|---|---|
| **simple** | 1-2 steps, single file, no state change, no decisions |
| **medium** | 3-5 steps, single domain, reversible, no external side effects |
| **complex** | Multi-domain, architectural, cross-file refactor, new feature, ambiguous requirements |
| **high-risk** | Destructive (rm -rf, DROP, force-push, db migration on prod), secrets handling, package publish, mass edits >20 files, irreversible network calls, anything touching production |

A "simple" task that drops a prod table is **high-risk**.

### Step 3 — Scan installed skills

Run the bundled scanner. It reads SKILL.md frontmatter only (cheap), auto-invalidates when SKILL.md / plugin.json / installed_plugins.json files change, and emits one line per skill: `name|source|description`.

```bash
bash "${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/skill-triage}/scripts/scan-skills.sh"
```

`${CLAUDE_SKILL_DIR}` is set by Claude Code to this skill's install directory, so the scanner is reachable whether the skill is installed as a personal skill (`~/.claude/skills/skill-triage/`), as a plugin (`~/.claude/plugins/cache/<mkt>/<plugin>/<ver>/skills/skill-triage/`), or via `--add-dir`. The fallback to `~/.claude/skills/skill-triage` handles environments where the variable is not set.

Source is one of `personal`, `plugin:<name>`, `plugin-mkt:<marketplace>`, `project`, or `extra`. A `!disabled` suffix (e.g. `plugin:foo!disabled`) means the skill sets `disable-model-invocation: true` — Claude will not auto-invoke it; recommend it only as a user-invoke `/command`.

If a skill was just installed and the file-level fingerprint hasn't caught up, pass `--refresh` to bust the cache:

```bash
bash "${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/skill-triage}/scripts/scan-skills.sh" --refresh
```

**Token-efficient scanning.** When the user's machine has 200+ installed skills, the full scan output can run 30 KB+ — a non-trivial chunk of context. Use the output-shaping flags to keep triage cheap:

```bash
# Cheap first pass: name|source only, no descriptions (~80% smaller output).
SCAN="${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/skill-triage}/scripts/scan-skills.sh"
bash "$SCAN" --brief

# Pre-filter on the scanner side before reading any descriptions.
bash "$SCAN" --filter "$KEYWORD"

# Combine: top-N brief matches for a keyword.
bash "$SCAN" --filter "$KEYWORD" --limit 20

# Then upgrade only the 1-3 finalists to full descriptions:
bash "$SCAN" --filter "$FINALIST_NAME"
```

Use `--brief --filter <keyword>` for the Step-4 enumeration pass, then a second
narrow call for the 1-3 finalists. This is materially cheaper than reading the
full scan into context.

### Step 4 — Triage

From the scanner output:

1. **Filter** by keyword overlap with the task (substring match against name + description). Drop the rest.
2. **Rank** the remaining 0-10 candidates by fit. Heuristic: process skills (planning, debugging, brainstorming) first if the task hasn't been scoped; implementation skills next; post skills (review, test, docs, ship) if the task is "complete X and merge."
3. **Read full SKILL.md** for at most the top 1-3 candidates. Use the `Read` tool. Skip if the frontmatter description already gives you enough to decide.
4. **Resolve conflicts.** When several skills overlap (e.g., two reviewers, two designers), pick exactly one winner per role and list the rejected ones with a one-line reason. Do not chain redundant skills "for safety."

### Step 4b — Apply the skill budget (HARD CAP)

After triage, check your "Relevant skills" list against this budget by complexity tier:

| Tier | Max relevant skills |
|---|---|
| simple | 0 (use short-form) |
| medium | 1-2 |
| complex | 3-5 |
| high-risk | 1-2 (the safety wrap + at most one planner) |

**One skill per role.** Roles: scope/brainstorm, plan, design, implement, review, test, ship, debug. If the user has two planning skills, pick one and demote the others to **Avoid** with the reason "redundant with X." Same for two reviewers, two designers, two debuggers.

**Self-check before emitting.** Count "Relevant skills" entries.
- Over budget? Cut the weakest. Move it to Avoid with a one-line reason. Re-count.
- At or under budget? Proceed.

A router that lists 8 plausible skills is not routing — it is a directory dump. The user can read the directory themselves. The value is the cut.

### Step 4c — Discovery fallback (when nothing matches)

**Privacy escape hatch (check first).** If `SKILL_TRIAGE_NO_DISCOVERY=1` is set
in the environment, skip Step 4c entirely and fall through to a `proceed directly`
verdict. Some users / managed environments disable network discovery wholesale.

Trigger this step **only** when one of the following is true after Step 4b:

- The scanner returned zero skills (new Claude Code user, no skills installed).
- The scanner returned skills but none match the task by keyword + role fit.

Otherwise skip this step entirely.

**Privacy first.** Before any web call, scrub the task to safe keywords. Drop emails, names, IDs, file paths, URLs, hostnames, secrets, and any quoted user data. Send only generic terms (e.g., for "delete the user with email foo@bar.com from prod" send `database delete row`). The user's raw task must not leave the machine.

Search for skills the user could install. Use this allow-list **first**, in order:

1. `https://raw.githubusercontent.com/anthropics/skills/main/README.md` — official Anthropic skills repo
2. `https://raw.githubusercontent.com/travisvn/awesome-claude-skills/main/README.md` — community awesome list
3. `https://raw.githubusercontent.com/hesreallyhim/awesome-claude-code/main/README.md` — community awesome list

Use `WebFetch` on each. If a `main`-branch URL returns 404 or empty content, retry once with `master` in place of `main`. Extract candidate skills whose name + description overlap with the (scrubbed) task keywords. If the allow-list yields nothing useful, fall back to `WebSearch` with the (scrubbed) query:

```
claude code skill <safe keywords> site:github.com
```

For every candidate from either path, **verify** before suggesting:

- `WebFetch` `https://raw.githubusercontent.com/<owner>/<repo>/main/SKILL.md`. If 404, try `https://raw.githubusercontent.com/<owner>/<repo>/main/skills/<skill-name>/SKILL.md`, then the same two paths on the `master` branch.
- If all four 404, drop the candidate. Never invent a name.
- Reject any candidate whose name contains shell metacharacters (`spaces`, `;`, `|`, `&`, backticks, `$`, `(`, `)`).

Cap discovery output at **3** suggestions. One per role.

Emit using this template (instead of the regular routing plan):

```markdown
## Discovery suggestion

No installed skill matches this task. Verified candidates from the web:

- **<skill-name>** ([repo](<github-url>)) — <one-line description from the source>
  - Install:
    ```
    SKILL=<skill-name>
    DIR=$(mktemp -d) && git clone --depth 1 <repo-url> "$DIR" \
      && mkdir -p ~/.claude/skills \
      && cp -r "$DIR/skills/$SKILL" ~/.claude/skills/ \
      && rm -rf "$DIR"
    ```
  - Source: <anthropics/skills | travisvn/awesome-claude-skills | hesreallyhim/awesome-claude-code | web-search:<owner>/<repo>>
  - Note: third-party skill — review its SKILL.md and any bundled scripts before running.

**Verdict:** install one of the above and re-run skill-triage, or `proceed directly` without a skill.
```

If the upstream repo's directory layout differs from `skills/<name>/` (some community repos place `SKILL.md` at the root), say so in the suggestion and link the repo's README instead of emitting a possibly-wrong install command.

If discovery itself returns nothing usable, fall through to a plain `proceed directly` verdict — do not invent suggestions.

**Tool availability.** `WebFetch` and `WebSearch` may not exist in every Claude Code environment. Try them; on tool error, fall through to `proceed directly`. Do not retry, do not error-out.

### Step 5 — Risk gate

If the task is **high-risk**, the verdict is **stop and ask** — even if a skill perfectly matches. Use `AskUserQuestion` with concrete options (proceed / dry-run first / abort) before doing anything irreversible. Quote the destructive command verbatim in the question.

If the task is **complex + irreversible-strategic** (vertical pick, architecture lock-in, public launch, co-founder equity, public commitments, multi-week roadmap commits), the verdict is **stop and ask** — even though the code itself is reversible, the strategic commitment is not. Strategic decisions accrete sunk-cost momentum that's structurally hard to unwind. Use `AskUserQuestion` to confirm the routing + scope before invoking the recommended skill chain.

If the task is **complex** but reversible AND non-strategic (refactor, debugging, exploration, technical investigation), the verdict is **proceed with skill(s)** — emit the recommendation and continue without asking.

If **simple** or **medium** with a clear single skill, **proceed with skill(s)**.

If **simple** with no skill that adds value, **proceed directly** (no skill).

### Step 6 — Emit the recommendation

Use this exact template. The "no skill needed" case uses the short form below; never emit the full template with empty sections.

```markdown
## Routing plan

**Task:** <one-sentence restatement>
**Complexity:** simple | medium | complex | high-risk
**Risk flags:** <none | destructive | secrets | prod | irreversible | mass-edit>

**Relevant skills:**
- `<skill-name>` (<source>) — <one-line why this fits>
- ...

**Avoid:**
- `<skill-name>` — <one-line why not (e.g., "scope mismatch", "post-impl only", "redundant with X")>

**Recommended order:**
1. **pre:** `/skill-a` — <purpose>
2. **impl:** `/skill-b` — <purpose>
3. **post:** `/skill-c` — <purpose>

**Verdict:** proceed directly | proceed with skill(s) | stop and ask
```

**Short form (no skill needed):**

```markdown
**Routing:** No skill needed — <one-line reason>. Proceeding directly.
```

### Step 7 — Gate (when applicable)

If verdict is **stop and ask**, immediately follow the recommendation with an `AskUserQuestion` call. Options should be concrete and mutually exclusive — never "proceed / abort" alone; include a middle path like "dry-run first" or "narrow scope to X."

If `AskUserQuestion` is not available in the current environment (some non-Claude-Code agents), ask in plain text and wait for a reply before doing anything irreversible.

If verdict is **proceed with skill(s)**, do **not** ask — just execute the first recommended skill.

If verdict is **proceed directly**, do not ask, do not invoke a skill.

## Design principles (read these — they explain the *why*)

**Conservative by default.** Most tasks need 0-1 skills, not 3. The triage exists to *prevent* skill thrash, not justify it. If you are recommending 4+ skills for a single task, you are wrong — re-read the task.

**Installed skills first, web second.** The default mode is to route among what the user already has. The web discovery fallback exists only because a brand-new install of skill-triage on a machine with no other skills would otherwise be useless. Discovery is the cold-start fix, not the main loop.

**Don't blow context.** The scanner returns ~300 skill descriptions in a few KB. Do not `Read` every SKILL.md — only the 1-3 finalists. Progressive disclosure means triage on metadata first.

**Pick winners, name losers.** Listing every plausible skill is unhelpful — the user already has them listed. The value is the *judgment*: this one, not those, because X. The "Avoid" section prevents future-you from reaching for the wrong tool 10 minutes later.

**Risk gates before skill matches.** A perfect skill for a destructive task still requires user confirmation. Triage does not bypass safety. Quote destructive commands verbatim — never paraphrase `rm -rf` as "delete some files."

**Phase ordering matters.** Calling a review skill before code is written wastes a turn. Calling a brainstorming skill after implementation is too late. The pre/impl/post grouping forces honest sequencing.

**Advisory, not authoritative.** Skill-triage does not enter plan mode. It does not block tool calls. It emits a recommendation and lets the caller (Claude or the user) decide. If the user overrides — "no, just do it directly" — drop the recommendation and comply.

## Examples

Four worked examples (medium / high-risk / no-skill / multi-skill) live in
[`examples/templates.md`](examples/templates.md). Open them only when you need
a template to crib from — they're kept out of the main skill body to save
context budget on every invocation.

## What NOT to do

- Do not recommend a skill-creator skill unless the user explicitly wants a new skill.
- Do not recommend more than one skill per role (one planner, one reviewer, etc.).
- Do not silently omit a strong candidate — list it under "Avoid" with a reason.
- Do not invent slash commands. Verify the skill exists in the scanner output (or, in discovery fallback, on a verified web URL) before suggesting `/<name>`.
- Do not run discovery fallback when the scanner already returned at least one matching skill. The fallback is for empty-result cases only.
- Do not invent or hallucinate skill names from `WebSearch` results. If the candidate URL 404s or its repo has no `SKILL.md`, drop it.
- Do not enter plan mode. Leave that to the caller's configuration.
- Do not paraphrase destructive commands. Quote them.
- Do not run on follow-up turns inside an existing skill flow — would duplicate routing.

## Bundled resources

- `scripts/scan-skills.sh` — frontmatter-only scanner across personal / plugin / project skill dirs. Auto-invalidates the per-UID cache (under `${XDG_CACHE_HOME:-$HOME/.cache}/skill-triage/`) when `~/.claude/plugins/installed_plugins.json`, `~/.claude/skills`, the plugin cache, or the marketplaces dir change. Pass `--refresh` to force.
- `scripts/__tests__/test_scanner.sh` — regression test for the scanner. Run `bash scripts/__tests__/test_scanner.sh`.
- `examples/templates.md` — four worked routing-plan examples (medium, high-risk, no-skill, multi-skill chain).
- `examples/examples.json` — illustrative test prompts for iterating on this skill.

## Privacy

The discovery fallback (Step 4c) sends *scrubbed* task keywords — never raw user
task text — to a small allow-list of GitHub raw URLs, and (as a last resort) a
`WebSearch` query. Scrubbing drops emails, names, IDs, file paths, URLs,
hostnames, secrets, and any quoted user data before any network call. If you
cannot guarantee scrubbing on your platform, set `SKILL_TRIAGE_NO_DISCOVERY=1`
to disable Step 4c entirely.

## Limitations

- **Plugin manifest schema is undocumented.** The scanner parses
  `~/.claude/plugins/installed_plugins.json` to label plugin skills correctly;
  if Anthropic changes that file's shape, the scanner falls back to a glob walk
  of `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/skills/` and the
  official `${CLAUDE_PLUGIN_DATA}` path (`~/.claude/plugins/data/<id>/`).
- **Custom skill install roots** (anything outside `~/.claude/skills`,
  `~/.claude/plugins/{cache,data,marketplaces}`, or the project tree) must be
  added via `SKILL_TRIAGE_EXTRA_ROOTS=<dir>:<dir>` so the scanner is portable.
  Common power-user dirs to add: `~/.codex/skills`, `~/.claude/skill-creator`.
- **YAML parser is awk-based.** Handles `description:` /
  `description: |` / `description: >` (and `|-` / `>-` chomp), quoted scalars,
  and the `when_to_use:` companion field. Frontmatter outside the leading
  `---` delimiters is ignored. Block scalars with non-2-space indent may not
  fold correctly — file an issue with a fixture if you hit it.
- **Description budget = 250 chars** to match the Claude Code v2.1.86
  `/skills` listing cap (issue #40121). Longer descriptions are truncated.
- **Linux + macOS supported.** Windows is untested; the scanner uses POSIX
  `find -L`, BSD/GNU `stat`, and a `bash` shebang. CI matrix covers
  Ubuntu, macOS (Homebrew bash 5 and `/bin/bash` 3.2), and Alpine (BusyBox).
- **Listing budget.** Claude Code allocates ~1% of the model context window to
  skill-listing descriptions (configurable via `skillListingBudgetFraction`
  setting or `SLASH_COMMAND_TOOL_CHAR_BUDGET` env). Overflow drops
  least-invoked skills' descriptions first. Run `/doctor` to inspect overflow.
  The 250-char-per-row scanner cap is sized to fit this budget for typical
  installs.

## See also

- [CHANGELOG.md](../../CHANGELOG.md) — version history
- [SECURITY.md](../../SECURITY.md) — privacy model for the Step-4c discovery fallback
- [CONTRIBUTING.md](../../CONTRIBUTING.md) — how to file issues / PRs
