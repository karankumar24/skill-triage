# Changelog

All notable changes to skill-triage are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.2.0] - 2026-05-17

Scanner correctness, security, and OSS-portability overhaul. Originally
prompted by a user report that the scanner missed several installed skills
on first invocation; root-cause analysis exposed a broader class of bugs.

### Fixed
- **Symlinked personal skills dropped.** `find` ran without `-L`, so any
  `~/.claude/skills/<x>` that is a symlink into `~/.agents/skills/`,
  `~/.codex/skills/`, or anywhere else was silently skipped. Now uses
  `find -L` everywhere.
- **Plugin label was the marketplace name, not the plugin.** Every skill
  shipped under `claude-plugins-official` was labelled
  `plugin:claude-plugins-official`, collapsing distinct plugins (vercel,
  figma, superpowers, frontend-design, …) into one bucket. Scanner now
  parses `~/.claude/plugins/installed_plugins.json` to recover the real
  plugin name (`plugin:vercel`, `plugin:figma`, …).
- **`~/.claude/plugins/data/<id>/` ignored.** This is the official
  `${CLAUDE_PLUGIN_DATA}` directory per Claude Code docs; skills installed
  there were invisible. Now walked.
- **`plugin.json:skills` custom paths ignored.** Plugin manifests may add
  extra skill directories via a `skills` string or array; the scanner
  never read them. Now parses string form, inline-array form
  (`"skills": ["a","b"]`), and multi-line array form.
- **Project skill walk was CWD-relative only.** Running the skill from any
  directory other than the repo root missed `<repo>/.claude/skills/`. Now
  detects git root and additionally walks every nested `.claude/skills/`
  for monorepo support.
- **Cache returned stale results for up to 10 minutes after any change.**
  Replaced TTL-only cache with `find -newer` over SKILL.md / plugin.json /
  installed_plugins.json, a sidecar fingerprint (`path|size|mtime` cksum)
  that catches deletes and renames, and a per-context cache filename
  (hash of git-root + extras) so switching projects cannot reuse the
  wrong cache.
- **Plugin path traversal.** A malicious `plugin.json` declaring
  `skills: ["../../../etc"]` would have been walked. Now: `..` segments
  and absolute paths are rejected before resolution; the candidate is
  canonicalised via `pwd -P` and confined to the canonical plugin root;
  each discovered SKILL.md is rechecked so a symlink trap placed inside
  an otherwise-confined `skills/` tree cannot escape either.
- **Row-injection / ANSI smuggling.** `name`, `source`, and `description`
  fields were not sanitised; a hostile SKILL.md with a newline or pipe
  in `name:`, or an ESC byte in `description:`, could inject extra PSV
  rows or leak ANSI escapes into the user's terminal. All three fields
  now strip NUL, C0 controls, DEL, and `|`; UTF-8 continuation bytes
  (0x80-0x9F) are preserved.
- **YAML edge cases.** Leading UTF-8 BOM, CRLF line endings, and inline
  `#` comments on unquoted scalars caused frontmatter to misparse or
  embed garbage. Now pre-stripped before awk; quoted scalars containing
  a literal `#` are preserved per YAML rules.
- **BSD vs GNU `stat` detection was inverted.** GNU `stat -f` means
  `--file-system`, not "format string" as on BSD. The detector chose the
  wrong code path on Linux, causing `cache_mtime` to be parsed as
  multiline `File: ...` output and aborting with `File: unbound
  variable`. Now probes with GNU `-c` first, BSD `-f` fallback.

### Added
- **`SKILL_TRIAGE_EXTRA_ROOTS=<dir>[:<dir>...]`** env for power-user
  install roots (`~/.codex/skills`, `~/.claude/skill-creator`, custom org
  paths) without hardcoding any one user's layout into OSS code.
- **`SKILL_TRIAGE_NO_DISCOVERY=1`** env documented in Step 4c as a
  privacy escape hatch for managed environments.
- **`when_to_use:` frontmatter field** concatenated into description so
  triage signal is richer for skills that lean on this field.
- **`disable-model-invocation: true` flagging.** Such skills cannot be
  auto-invoked by Claude; scanner now suffixes their source with
  `!disabled` so triage can recommend them as user-invoke only.
- **`${CLAUDE_SKILL_DIR}`** used for the scanner invocation in SKILL.md
  so the skill works whether installed personally, as a plugin, or via
  `--add-dir` (replaces hardcoded `~/.claude/skills/skill-triage/...`).
- **`examples/templates.md`** — four worked routing-plan examples
  extracted from SKILL.md (saves ~400 tokens per skill load by keeping
  the always-in-context body small).
- **`scripts/__tests__/test_scanner.sh`** — 24-assertion regression test
  covering every bug above. Fixtures are built at runtime under
  `mktemp -d`; environment is isolated (`HOME`, `XDG_*`, `GIT_DIR`,
  `GIT_WORK_TREE`, `GIT_INDEX_FILE`) so the test cannot read the
  user's real machine state.
- **`.github/workflows/ci.yml` matrix job** runs the regression suite on
  both ubuntu-latest and macos-latest, verifying behaviour against both
  BSD and GNU coreutils every push and PR.

### Changed
- Description budget cut 280 → 250 chars to match the Claude Code
  v2.1.86 `/skills` listing cap (anthropics/claude-code#40121).
- Cache filename bumped `cache.v2 → cache.v3` (new context-key + sidecar
  fingerprint schema). Legacy v2 files are left in place but ignored.
- Plugin-cache fallback walk no longer dedups by string-equal full paths
  (`|`-delimited string membership corrupted by paths containing `|`).
  Switched to newline-delimited set membership.

### Security
- All discovered SKILL.md paths are canonicalised before being walked
  inside a plugin scope; combined with the path-traversal guards above,
  a malicious plugin cannot make the scanner read arbitrary readable
  directories on the user's machine.

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
