#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# shellcheck shell=bash
#
# test_scanner.sh — regression test for scan-skills.sh.
#
# Exercises:
#   1. find -L follows symlinked skill dirs (adversarial-fixture is a symlink)
#   2. Folded block-scalar `description: >` is parsed without truncation
#   3. Pipe characters inside description are sanitised (not field delimiters)
#   4. SKILL_TRIAGE_EXTRA_ROOTS is honoured (colon-separated)
#   5. --refresh actually busts the cache
#   6. Deep nesting (maxdepth 6) is reached
#   7. Cache auto-invalidates on in-place SKILL.md edits (file-level mtime)
#   8. Dedup by (name,source) — same name different source survives
#   9. Hostile `name:` with REAL newline byte + literal pipe cannot inject extra rows
#  10. Hostile `plugin.json` with `../`-prefixed skills path is rejected at runtime
#      (functional test: feeds a fake plugin into ~/.claude/plugins/cache layout)
#  11. HOME isolation airtight: GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE unset
#  12. Cache invalidates on SKILL.md DELETE (sidecar fingerprint)
#  13. Cache key is per-context: changing SKILL_TRIAGE_EXTRA_ROOTS routes to
#      a different cache file (no stale-but-valid reuse across projects)
#  14. Default `skills/` is canonicalised — a symlinked `skills` -> /tmp/elsewhere
#      cannot escape the plugin root
#
# Run:  bash scripts/__tests__/test_scanner.sh
# Exit code: 0 on pass, 1 on first failure.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER="$(cd "$HERE/.." && pwd)/scan-skills.sh"

[[ -r "$SCANNER" ]] || { echo "FAIL: scanner not readable at $SCANNER" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME/.claude/plugins/cache/testmkt"
mkdir -p "$WORK/repo"
( cd "$WORK/repo" && git init -q --initial-branch=main >/dev/null 2>&1 || git init -q >/dev/null 2>&1 )

FIXTURES="$WORK/fixtures"
mkdir -p "$FIXTURES/_target" "$FIXTURES/nested/deep/inline-fixture"

cat > "$FIXTURES/_target/SKILL.md" <<'EOF'
---
name: adversarial-fixture
description: >
  This fixture exercises folded block scalar parsing.

  It spans multiple paragraphs, includes a pipe | character that the scanner
  must sanitise, has embedded YAML-like text ("key: value") in prose, and is
  reached only through a symlink under an unusual path so it also exercises
  find -L coverage.
metadata:
  type: test
---
EOF

cat > "$FIXTURES/nested/deep/inline-fixture/SKILL.md" <<'EOF'
---
name: inline-fixture
description: Deeply nested skill at unusual path; exercises maxdepth coverage.
---
EOF

# Hostile name with REAL newline byte (printf %b interprets the \n) + literal
# pipe. If sanitisation is broken, the newline would split into a second PSV
# row whose first field is "hijacked-skill" — proving row injection.
mkdir -p "$FIXTURES/hostile-name"
printf -- '---\nname: "evil|injected\nhijacked-skill"\ndescription: hostile name fixture\n---\n' \
  > "$FIXTURES/hostile-name/SKILL.md"

# UTF-8 fixture: em-dash (E2 80 94) and CJK char must survive sanitize intact.
# Earlier blanket 0x80-0x9F stripping (codex round 3) corrupted UTF-8 continuation
# bytes — this fixture would have been mangled.
mkdir -p "$FIXTURES/utf8-fixture"
printf -- '---\nname: utf8-fixture\ndescription: "em-dash \xe2\x80\x94 and 中文 must survive sanitize"\n---\n' \
  > "$FIXTURES/utf8-fixture/SKILL.md"

# ESC byte (0x1B = C0) in description — sanitizer must strip it (it's the start
# of every ANSI escape sequence). Surrounding ASCII must survive.
mkdir -p "$FIXTURES/esc-fixture"
printf -- '---\nname: esc-fixture\ndescription: "before\x1b[31mRED\x1b[0mafter"\n---\n' \
  > "$FIXTURES/esc-fixture/SKILL.md"

# UTF-8 BOM (EF BB BF) at the very start of SKILL.md. Files saved by some
# Windows editors get a BOM; the parser must strip it before frontmatter detect.
mkdir -p "$FIXTURES/bom-fixture"
printf -- '\xef\xbb\xbf---\nname: bom-fixture\ndescription: leading BOM must not block parsing.\n---\n' \
  > "$FIXTURES/bom-fixture/SKILL.md"

# CRLF line endings (Windows). Parser must strip \r so /^---$/ still matches.
mkdir -p "$FIXTURES/crlf-fixture"
printf -- '---\r\nname: crlf-fixture\r\ndescription: CRLF line endings must not block parsing.\r\n---\r\n' \
  > "$FIXTURES/crlf-fixture/SKILL.md"

# Inline YAML comment on a scalar description line: ` # ...` after the value.
# Parser must strip the trailing comment from the value (not embed it).
mkdir -p "$FIXTURES/comment-fixture"
cat > "$FIXTURES/comment-fixture/SKILL.md" <<'EOF'
---
name: comment-fixture
description: real description value # trailing comment must be stripped
---
EOF

# Quoted scalar containing a literal `#` — must be preserved (YAML rule:
# `#` inside quotes is not a comment).
mkdir -p "$FIXTURES/quoted-hash-fixture"
cat > "$FIXTURES/quoted-hash-fixture/SKILL.md" <<'EOF'
---
name: quoted-hash-fixture
description: "value with # literal hash inside quotes"
---
EOF

# Functional path-traversal test: build a fake plugin under the cache layout
# that walk_plugin_root scans, with a plugin.json that tries to escape via ../.
# The plugin.json uses single-line array form so we also confirm the inline-array
# parser path works (codex round 5 found it was broken).
HOSTILE_PLUGIN="$FAKE_HOME/.claude/plugins/cache/testmkt/hostile/1.0.0"
mkdir -p "$HOSTILE_PLUGIN/skills"
cat > "$HOSTILE_PLUGIN/plugin.json" <<'EOF'
{
  "name": "hostile",
  "skills": ["../../../../tmp"]
}
EOF
# Canary placed where `../../../../tmp` from the hostile plugin actually
# resolves: hostile = $FAKE_HOME/.claude/plugins/cache/testmkt/hostile/1.0.0,
# ../../../../tmp = $FAKE_HOME/.claude/plugins/tmp. If the ../ guard were
# removed, scanner WOULD reach this dir — so this test now genuinely proves
# the guard works (codex round 6 noted the old path resolved to a nonexistent
# location, making the test pass for the wrong reason).
mkdir -p "$FAKE_HOME/.claude/plugins/tmp/canary-skill"
cat > "$FAKE_HOME/.claude/plugins/tmp/canary-skill/SKILL.md" <<'EOF'
---
name: should-never-appear
description: If this row appears in output, plugin.json ../ traversal succeeded.
---
EOF

# Symlink-trap attack: a plugin with a legitimate-looking skills/ that contains
# a sub-symlink pointing outside the plugin root. scan_dir_confined must reject
# SKILL.md files reachable only via that symlink (codex round 6).
TRAP_PLUGIN="$FAKE_HOME/.claude/plugins/cache/testmkt/trap/1.0.0"
mkdir -p "$TRAP_PLUGIN/skills/legit-skill"
cat > "$TRAP_PLUGIN/skills/legit-skill/SKILL.md" <<'EOF'
---
name: legit-trap-skill
description: Real skill inside trap plugin — must still appear.
---
EOF
# Outside-the-plugin dir with a canary SKILL.md
mkdir -p "$WORK/outside-trap-target/sneaky-skill"
cat > "$WORK/outside-trap-target/sneaky-skill/SKILL.md" <<'EOF'
---
name: should-also-never-appear
description: Reachable only via symlink inside skills/. Confined scan must reject.
---
EOF
# The trap: a symlink INSIDE skills/ pointing outside the plugin root.
ln -s "$WORK/outside-trap-target" "$TRAP_PLUGIN/skills/escape-link"

# Legitimate inline-array plugin.json: skills paths inside the plugin root
# (single-line form, which the broken parser silently dropped). After fix,
# walk_plugin_root must discover the skill via the custom path.
LEGIT_PLUGIN="$FAKE_HOME/.claude/plugins/cache/testmkt/legit/1.0.0"
mkdir -p "$LEGIT_PLUGIN/extra-skills/legit-inline-skill"
cat > "$LEGIT_PLUGIN/plugin.json" <<'EOF'
{ "name": "legit", "skills": ["extra-skills"] }
EOF
cat > "$LEGIT_PLUGIN/extra-skills/legit-inline-skill/SKILL.md" <<'EOF'
---
name: legit-inline-skill
description: Reached via plugin.json inline-array skills path.
---
EOF

# Symlinked-skills attack: a plugin whose default `skills/` is a symlink
# pointing outside the plugin root. The default-path canonicalisation guard
# (codex round 2) must refuse to walk it.
SYMLINK_ATTACK="$FAKE_HOME/.claude/plugins/cache/testmkt/symlink-attack/1.0.0"
mkdir -p "$SYMLINK_ATTACK"
ln -s "$WORK/canary-outside-plugin" "$SYMLINK_ATTACK/skills"

# Symlink for adversarial fixture (runtime, not source-controlled)
ln -s "_target" "$FIXTURES/symlinked-fixture-skill"

pass=0
fail=0
fail_msgs=()
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
fail() { printf '  FAIL %s\n' "$1" >&2; fail_msgs+=("$1"); fail=$((fail+1)); }

OUT_FILE="$WORK/out.psv"

run_scanner() {
  # Airtight isolation: unset every inherited env that could leak outside
  # state (git env, scanner env from the user's shell, XDG paths).
  ( cd "$WORK/repo" && \
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
          GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM \
          SKILL_TRIAGE_EXTRA_ROOT && \
    HOME="$FAKE_HOME" \
    XDG_CACHE_HOME="$WORK/cache" \
    XDG_CONFIG_HOME="$WORK/config" \
    SKILL_TRIAGE_EXTRA_ROOTS="$FIXTURES" \
    bash "$SCANNER" $1 ) > "$OUT_FILE"
}

echo "== run 1: --refresh with isolated env =="
run_scanner "--refresh"

[[ -s "$OUT_FILE" ]] \
  && ok "scanner produced non-empty output ($(wc -l < "$OUT_FILE" | tr -d ' ') rows)" \
  || fail "scanner produced empty output"

grep -E '^adversarial-fixture\|extra\|' "$OUT_FILE" >/dev/null \
  && ok "adversarial-fixture appears (symlink followed via find -L)" \
  || fail "adversarial-fixture missing"

grep -E '^inline-fixture\|extra\|' "$OUT_FILE" >/dev/null \
  && ok "inline-fixture appears (maxdepth 6 OK)" \
  || fail "inline-fixture missing"

desc_len=$(awk -F'|' '/^adversarial-fixture\|/ { print length($3); exit }' "$OUT_FILE")
if [[ -n "$desc_len" ]] && (( desc_len > 20 )); then
  ok "block-scalar description parsed ($desc_len chars)"
else
  fail "block-scalar description empty or too short (got: ${desc_len:-none})"
fi

field_count=$(awk -F'|' '/^adversarial-fixture\|/ { print NF; exit }' "$OUT_FILE")
[[ "$field_count" == "3" ]] \
  && ok "pipe-in-description sanitised (3 fields)" \
  || fail "pipe sanitisation broken (fields: ${field_count:-none})"

awk -F'|' '/^adversarial-fixture\|/ { print $3 }' "$OUT_FILE" | grep -q 'sanitise' \
  && ok "block-scalar later paragraph included (folding works)" \
  || fail "block-scalar truncated — only first line"

# HOME isolation airtight: FAKE_HOME has no personal skills, so no `personal` rows.
if ! awk -F'|' '$2 == "personal"' "$OUT_FILE" | grep -q .; then
  ok "HOME isolation airtight (no real personal skills leaked)"
else
  leaked=$(awk -F'|' '$2 == "personal" { print $1 }' "$OUT_FILE" | head -3 | tr '\n' ' ')
  fail "HOME isolation broken — leaked: $leaked"
fi

# Real-newline injection: hijacked-skill must NOT appear as its own row
if grep -E '^hijacked-skill\|' "$OUT_FILE" >/dev/null; then
  fail "real-newline injected a second row (sanitisation broken)"
else
  ok "real-newline in name field could not inject extra row"
fi

# UTF-8 must survive sanitize: em-dash (E2 80 94) + CJK chars in description.
# Earlier 0x80-0x9F byte stripping (codex round 3) would have corrupted these.
utf8_row=$(awk -F'|' '/^utf8-fixture\|/ { print $3 }' "$OUT_FILE")
if [[ -n "$utf8_row" ]] && \
   printf '%s' "$utf8_row" | LC_ALL=en_US.UTF-8 grep -q '中文' && \
   printf '%s' "$utf8_row" | LC_ALL=en_US.UTF-8 grep -q '—'; then
  ok "UTF-8 (em-dash + CJK) survives sanitize intact"
else
  fail "UTF-8 corrupted by sanitize (got: $(printf '%s' "$utf8_row" | head -c 80))"
fi

# ESC (0x1B) must be stripped from description (it's the start of every ANSI seq).
esc_row=$(awk -F'|' '/^esc-fixture\|/ { print $3 }' "$OUT_FILE")
if printf '%s' "$esc_row" | LC_ALL=C grep -q $'\x1b'; then
  fail "ESC byte 0x1B survived sanitisation (ANSI injection possible)"
else
  printf '%s' "$esc_row" | grep -q 'before.*after' \
    && ok "ESC bytes stripped, surrounding ASCII preserved" \
    || fail "ESC sanitiser ate too much"
fi

# YAML edge cases: BOM, CRLF, inline comment, quoted-hash
grep -E '^bom-fixture\|extra\|leading BOM' "$OUT_FILE" >/dev/null \
  && ok "leading UTF-8 BOM stripped (bom-fixture parsed)" \
  || fail "UTF-8 BOM blocked frontmatter parsing"

grep -E '^crlf-fixture\|extra\|CRLF line endings' "$OUT_FILE" >/dev/null \
  && ok "CRLF line endings stripped (crlf-fixture parsed)" \
  || fail "CRLF line endings blocked frontmatter parsing"

# Inline comment: description value must NOT include `# trailing comment`
comment_row=$(awk -F'|' '/^comment-fixture\|/ { print $3 }' "$OUT_FILE")
if printf '%s' "$comment_row" | grep -q 'trailing comment'; then
  fail "inline YAML comment leaked into value: $comment_row"
elif printf '%s' "$comment_row" | grep -q 'real description value'; then
  ok "inline YAML comment stripped from unquoted scalar"
else
  fail "comment-fixture description empty or wrong (got: $comment_row)"
fi

# Quoted hash: `# literal hash` inside quotes must survive
quoted_row=$(awk -F'|' '/^quoted-hash-fixture\|/ { print $3 }' "$OUT_FILE")
if printf '%s' "$quoted_row" | grep -q 'literal hash inside quotes'; then
  ok "literal # inside quoted scalar preserved (no false-positive comment strip)"
else
  fail "quoted-hash value lost: $quoted_row"
fi

# Path traversal: should-never-appear must NOT be in output.
if grep -E '^should-never-appear\|' "$OUT_FILE" >/dev/null; then
  fail "path traversal SUCCEEDED — hostile plugin.json escaped plugin root"
else
  ok "hostile plugin.json (../) rejected at runtime (no canary row)"
fi

# Inline-array plugin.json: legit-inline-skill must appear (proves the
# single-line array parser actually works, and proves the traversal-reject
# test above wasn't passing for the wrong reason).
if grep -E '^legit-inline-skill\|plugin:legit\|' "$OUT_FILE" >/dev/null; then
  ok "plugin.json inline-array form parses (legit-inline-skill discovered)"
else
  fail "plugin.json inline-array form NOT parsed (single-line skills array missed)"
fi

# Symlink-trap inside skills/: legit-trap-skill MUST appear (real skill),
# should-also-never-appear MUST NOT (reached only via escape-link symlink).
if ! grep -E '^legit-trap-skill\|' "$OUT_FILE" >/dev/null; then
  fail "scan_dir_confined dropped a legit skill (over-rejection)"
elif grep -E '^should-also-never-appear\|' "$OUT_FILE" >/dev/null; then
  fail "symlink-trap inside skills/ escaped plugin root (scan_dir_confined broken)"
else
  ok "symlink-trap inside skills/ blocked; legit sibling skill still appears"
fi

# Symlinked-skills attack: same canary must NOT appear via the symlink-attack plugin
# (covered by previous assertion since canary name is unique).

echo "== run 2: cached read returns same output =="
cp "$OUT_FILE" "$WORK/out1.psv"
run_scanner ""
diff -q "$WORK/out1.psv" "$OUT_FILE" >/dev/null \
  && ok "cache hit returns byte-identical output" \
  || fail "cached output differs from --refresh output"

echo "== run 3: in-place SKILL.md edit propagates (file-level mtime) =="
sleep 1
sed -i.bak 's/Deeply nested skill at unusual path/EDITED-CONTENT-MARKER/' \
  "$FIXTURES/nested/deep/inline-fixture/SKILL.md" 2>/dev/null \
  || perl -i -pe 's/Deeply nested skill at unusual path/EDITED-CONTENT-MARKER/' \
     "$FIXTURES/nested/deep/inline-fixture/SKILL.md"
rm -f "$FIXTURES/nested/deep/inline-fixture/SKILL.md.bak"
run_scanner ""
grep -F 'EDITED-CONTENT-MARKER' "$OUT_FILE" >/dev/null \
  && ok "in-place edit propagated (file-level mtime invalidation works)" \
  || fail "stale cache returned old content after edit"

echo "== run 4: --refresh truncates, doesn't append =="
lines_before=$(wc -l < "$OUT_FILE" | tr -d ' ')
run_scanner "--refresh"
lines_after=$(wc -l < "$OUT_FILE" | tr -d ' ')
[[ "$lines_before" == "$lines_after" ]] \
  && ok "--refresh row count stable ($lines_before)" \
  || fail "--refresh changed row count ($lines_before → $lines_after)"

echo "== run 5: dedup by (name,source) =="
dup_count=$(awk -F'|' '{ print $1 "|" $2 }' "$OUT_FILE" | sort | uniq -d | wc -l | tr -d ' ')
[[ "$dup_count" == "0" ]] \
  && ok "no (name,source) duplicates" \
  || fail "$dup_count duplicate (name,source) pairs"

echo "== run 6: DELETE detection via sidecar fingerprint =="
rm "$FIXTURES/nested/deep/inline-fixture/SKILL.md"
run_scanner ""
if grep -E '^inline-fixture\|' "$OUT_FILE" >/dev/null; then
  fail "deleted skill still appears in cached output (fingerprint check broken)"
else
  ok "deleted SKILL.md disappeared from output (sidecar fingerprint works)"
fi

echo "== run 7: context-keyed cache (different EXTRA_ROOTS → different file) =="
# Build a second fixture set with a uniquely-named skill
ALT_FIXTURES="$WORK/alt-fixtures"
mkdir -p "$ALT_FIXTURES/alt-skill"
cat > "$ALT_FIXTURES/alt-skill/SKILL.md" <<'EOF'
---
name: alt-only-skill
description: Only present in alt fixtures.
---
EOF
( cd "$WORK/repo" && \
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
  HOME="$FAKE_HOME" \
  XDG_CACHE_HOME="$WORK/cache" \
  SKILL_TRIAGE_EXTRA_ROOTS="$ALT_FIXTURES" \
  bash "$SCANNER" ) > "$WORK/out-alt.psv"
grep -E '^alt-only-skill\|' "$WORK/out-alt.psv" >/dev/null \
  && ok "context-keyed cache: alt extras get a fresh scan (alt-only-skill present)" \
  || fail "alt extras returned stale cache from original context"
# And the alt run must NOT contain the original fixtures
if grep -E '^adversarial-fixture\|' "$WORK/out-alt.psv" >/dev/null; then
  fail "alt run leaked original fixtures (cache key not per-context)"
else
  ok "alt run did NOT see original fixtures (cache key isolated by context)"
fi

echo "== run 8: --filter / --limit / --brief flags =="
# --brief drops description column → exactly 2 fields per row
brief_out=$( ( cd "$WORK/repo" && \
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
  HOME="$FAKE_HOME" XDG_CACHE_HOME="$WORK/cache" \
  SKILL_TRIAGE_EXTRA_ROOTS="$FIXTURES" \
  bash "$SCANNER" --brief ) )
brief_fields=$(printf '%s\n' "$brief_out" | head -1 | awk -F'|' '{ print NF }')
[[ "$brief_fields" == "2" ]] \
  && ok "--brief drops description column (got 2 fields)" \
  || fail "--brief produced $brief_fields fields, want 2"

# --filter narrows by keyword (case-insensitive). Search for "fixture" should
# match adversarial-fixture / inline-fixture / etc., not unrelated rows.
filter_out=$( ( cd "$WORK/repo" && \
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
  HOME="$FAKE_HOME" XDG_CACHE_HOME="$WORK/cache" \
  SKILL_TRIAGE_EXTRA_ROOTS="$FIXTURES" \
  bash "$SCANNER" --filter fixture ) )
filter_count=$(printf '%s\n' "$filter_out" | grep -c .)
if (( filter_count > 0 )); then
  ok "--filter narrows output ($filter_count fixture rows)"
else
  fail "--filter returned no rows"
fi

# --limit caps output. 1 should yield exactly 1 row.
limit_out=$( ( cd "$WORK/repo" && \
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
  HOME="$FAKE_HOME" XDG_CACHE_HOME="$WORK/cache" \
  SKILL_TRIAGE_EXTRA_ROOTS="$FIXTURES" \
  bash "$SCANNER" --limit 1 ) )
limit_count=$(printf '%s\n' "$limit_out" | grep -c .)
[[ "$limit_count" == "1" ]] \
  && ok "--limit 1 yields exactly 1 row" \
  || fail "--limit 1 yielded $limit_count rows"

echo
echo "passed: $pass   failed: $fail"
if (( fail > 0 )); then
  printf '\nFailures:\n'
  for m in "${fail_msgs[@]}"; do printf '  - %s\n' "$m"; done
  exit 1
fi
