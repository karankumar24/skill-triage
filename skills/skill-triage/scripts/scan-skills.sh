#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# shellcheck shell=bash
#
# scan-skills.sh — emit name|source|description for every installed skill.
# Source = personal | plugin:<plugin-name> | plugin-mkt:<marketplace> | project | extra
# One line per skill, pipe-delimited, description trimmed to 250 chars
# (matches the Claude Code v2.1.86 /skills listing cap; see issue #40121).
# Cache is per-UID + per-context under ${XDG_CACHE_HOME:-$HOME/.cache}/skill-triage/.
#
# Roots walked (Claude Code defaults only — works for any user):
#   personal:    ~/.claude/skills                       (find -L: follows symlinks)
#   plugins:     authoritative via ~/.claude/plugins/installed_plugins.json
#                  (schema is officially undocumented; treated as best-effort)
#                also walks plugin.json:skills custom paths, with path-traversal
#                  protection: `..` and absolute paths are rejected outright, then
#                  canonicalised (pwd -P) and prefix-matched against the canonical
#                  plugin root. The DEFAULT `skills/` path is canonicalised too,
#                  so a symlinked `skills` cannot escape the plugin root either.
#                also walks ~/.claude/plugins/data/ (official ${CLAUDE_PLUGIN_DATA})
#                fallback walk:    ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/skills/
#                marketplace walk: ~/.claude/plugins/marketplaces/<marketplace>/
#   project:     <git-root>/.claude/skills (incl. nested for monorepos) then $PWD/.claude/skills
#   extra:       $SKILL_TRIAGE_EXTRA_ROOTS  (colon-separated, for power users + tests)
#
# Power-user roots like ~/.codex/skills, ~/.claude/skill-creator, or custom org
# locations should be added via SKILL_TRIAGE_EXTRA_ROOTS rather than hardcoded
# (this is an open-source script — different users have different layouts).
#
# Description string is the concatenation of `description:` and `when_to_use:`
# frontmatter fields (both are recognised in current Claude Code skill schema).
#
# Output sanitisation: name, source, and description are all stripped of NUL,
# C0 controls (incl. ESC, the start byte for ANSI escapes), and DEL; LF/CR/TAB
# collapse to space; `|` is rewritten to `/`. Bytes 0x80-0x9F are deliberately
# NOT stripped because they are valid UTF-8 continuation bytes; stripping them
# would mangle every non-ASCII codepoint. A hostile SKILL.md cannot inject
# extra rows or break field separation.
#
# Cache validity: TTL (10 min) AND no SKILL.md / plugin.json / installed_plugins.json
# under any watched root (personal + plugins + project + extras) is newer than
# the cache file. File-level mtime via `find -newer -print -quit` catches
# in-place content edits. A sidecar `${CACHE}.fp` records the SKILL.md count
# so deletes are caught even though `find -newer` cannot see vanished files.
# Cache filename is keyed on (UID, git-root or PWD, extras) so switching
# projects or extra roots cannot reuse the wrong cache.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scan-skills.sh [--refresh] [--filter <kw>] [--limit <n>] [--brief] [--help]

  --refresh        Bust the cache and rescan from disk.
  --filter <kw>    Only emit rows whose name or description (case-insensitive)
                   contains <kw>. Multiple --filter accepted (AND).
  --limit <n>      Emit at most <n> rows after filtering. 0 = no limit.
  --brief          Drop the description column. Output becomes `name|source`.
                   Useful for cheap first-pass enumeration in token-constrained
                   contexts (saves ~80% of output bytes).
  --help, -h       Show this message.

Emits one line per skill: name|source|description (or name|source with --brief).

Env:
  SKILL_TRIAGE_EXTRA_ROOTS=<dir>[:<dir>...]   extra scan roots (colon-separated)
  SKILL_TRIAGE_EXTRA_ROOT=<dir>               (legacy alias for a single root)
EOF
}

REFRESH=0
BRIEF=0
LIMIT=0
FILTERS=()
while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --refresh) REFRESH=1; shift ;;
    --brief)   BRIEF=1; shift ;;
    --filter)  [[ -n "${2:-}" ]] || { echo "scan-skills.sh: --filter needs an arg" >&2; exit 2; }
               FILTERS+=("$2"); shift 2 ;;
    --limit)   [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "scan-skills.sh: --limit needs a non-negative integer" >&2; exit 2; }
               # Force base-10: bash arithmetic treats leading-zero numbers as
               # octal, so --limit 08 / 09 would error inside (( LIMIT > 0 )).
               LIMIT=$((10#$2)); shift 2 ;;
    "")        shift ;;
    *)         echo "scan-skills.sh: unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
done

umask 077
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/skill-triage"
mkdir -p "$CACHE_DIR"

get_mtime() {
  # GNU stat first (Linux/containers — most common). BSD stat fallback (macOS).
  # The reverse order was wrong: GNU `stat -f` means --file-system and can
  # silently succeed on valid paths, returning multiline output that arithmetic
  # evaluation then parses as an unbound variable reference (`File: unbound...`).
  stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null || echo 0
}

# Build extra-roots list from env (new colon-separated form + legacy single)
extra_roots=()
if [[ -n "${SKILL_TRIAGE_EXTRA_ROOTS:-}" ]]; then
  IFS=':' read -r -a extra_roots <<< "$SKILL_TRIAGE_EXTRA_ROOTS"
fi
if [[ -n "${SKILL_TRIAGE_EXTRA_ROOT:-}" ]]; then
  extra_roots+=("$SKILL_TRIAGE_EXTRA_ROOT")
fi

# Detect git root (or fall back to PWD) for project-root walk + cache key
git_root_for_key=""
if git_root_for_key=$(git rev-parse --show-toplevel 2>/dev/null) && [[ -z "$git_root_for_key" ]]; then
  git_root_for_key=""
fi
project_anchor="${git_root_for_key:-$PWD}"

# Context-keyed cache filename: hashing (project_anchor + extras) into the cache
# filename means switching projects or changing SKILL_TRIAGE_EXTRA_ROOTS routes
# to a different cache file. Without this, a stale-but-valid cache from another
# project would be reused. cksum is POSIX, portable, and good enough for keying.
context_key=$(printf '%s\n' "$project_anchor" "${SKILL_TRIAGE_EXTRA_ROOTS:-}" "${SKILL_TRIAGE_EXTRA_ROOT:-}" | cksum | awk '{print $1}')
CACHE="$CACHE_DIR/cache.v3.${UID:-$(id -u)}.${context_key}.psv"
CACHE_FP="${CACHE}.fp"
TTL=600

# All watched roots — these are scanned for both file-level mtime freshness and
# the SKILL.md count fingerprint.
watched_roots() {
  local roots=("$HOME/.claude/skills" "$HOME/.claude/plugins")
  [[ -n "$git_root_for_key" ]] && roots+=("$git_root_for_key/.claude/skills")
  roots+=("$PWD/.claude/skills")
  local er
  for er in "${extra_roots[@]:-}"; do
    [[ -n "$er" ]] && roots+=("$er")
  done
  local r
  for r in "${roots[@]}"; do
    [[ -d "$r" ]] && printf '%s\n' "$r"
  done
}

# Fingerprint of all SKILL.md files visible across watched roots.
# Encodes path + size + mtime per file, then cksum's the sorted listing.
# Catches deletes, adds, renames, AND content edits (size/mtime drift) —
# strictly stronger than a count-only fingerprint, which would miss a
# same-count delete+add pair (codex round 3).
disk_skill_fingerprint() {
  local r stat_args
  # Detect GNU vs BSD stat. Try GNU `-c <fmt>` first; if rejected, use BSD `-f`.
  # Avoid `stat -f` as a probe — on GNU it means --file-system, with surprising
  # success semantics that break detection (the get_mtime bug, fixed above).
  if stat -c '%Y' "$CACHE_DIR" >/dev/null 2>&1; then
    stat_args=(-c '%n|%s|%Y')
  else
    stat_args=(-f '%N|%z|%m')
  fi
  # `-exec stat ... {} +` won't invoke stat at all if no files match, so an
  # empty-roots install gets a clean (constant-cksum) fingerprint instead of
  # an xargs/stat exit-1 that pipefail would propagate to the whole script.
  while IFS= read -r r; do
    find -L "$r" -maxdepth 8 -name SKILL.md -exec stat "${stat_args[@]}" {} + 2>/dev/null
  done < <(watched_roots) \
    | LC_ALL=C sort \
    | cksum \
    | awk '{print $1 ":" $2}'
}

# Cache is valid only if:
#   1. file exists, mtime > 0, within TTL
#   2. no watched file (SKILL.md / plugin.json / installed_plugins.json) is
#      newer than cache (catches adds + in-place edits)
#   3. SKILL.md count matches the fingerprint (catches deletes)
cache_valid() {
  [[ -f "$CACHE" && -f "$CACHE_FP" ]] || return 1
  local cache_mtime now age
  cache_mtime=$(get_mtime "$CACHE")
  (( cache_mtime > 0 )) || return 1
  now=$(date +%s)
  age=$(( now - cache_mtime ))
  (( age < TTL )) || return 1

  local r newer
  while IFS= read -r r; do
    # -print -quit short-circuits at first match and is SIGPIPE-safe under
    # `set -euo pipefail` (unlike `... | head -1` which can race the pipe close).
    newer=$(find -L "$r" -maxdepth 8 \
      \( -name SKILL.md -o -name plugin.json -o -name installed_plugins.json \) \
      -newer "$CACHE" -print -quit 2>/dev/null)
    [[ -n "$newer" ]] && return 1
  done < <(watched_roots)

  local cached_fp current_fp
  cached_fp=$(cat "$CACHE_FP" 2>/dev/null || echo "")
  current_fp=$(disk_skill_fingerprint)
  [[ -n "$cached_fp" && "$cached_fp" == "$current_fp" ]] || return 1

  return 0
}

# Apply --filter / --limit / --brief at output time. Defined here (before the
# cache-hit early-exit) so both cached and freshly-scanned paths can use it.
# Cache always stores the full canonical scan — filtering before write would
# poison the cache for the next caller running with different flags.
apply_output_filters() {
  local input="$1" f
  for f in "${FILTERS[@]:-}"; do
    [[ -n "$f" ]] || continue
    # index() not `~` — `~` is awk ERE, so `--filter '[abc]'` or `C++` would
    # either error or match unintended rows. index() is literal substring,
    # which is what the docs promise.
    input=$(printf '%s\n' "$input" | LC_ALL=C awk -F'|' -v kw="$f" '
      BEGIN { kw = tolower(kw) }
      { if (index(tolower($1), kw) || index(tolower($3), kw)) print }
    ')
  done
  if (( BRIEF == 1 )); then
    input=$(printf '%s\n' "$input" | LC_ALL=C awk -F'|' '{ print $1 "|" $2 }')
  fi
  if (( LIMIT > 0 )); then
    input=$(printf '%s\n' "$input" | head -n "$LIMIT")
  fi
  printf '%s\n' "$input"
}

emit_cache_or_filtered() {
  if (( ${#FILTERS[@]} == 0 )) && (( BRIEF == 0 )) && (( LIMIT == 0 )); then
    cat "$CACHE"
  else
    apply_output_filters "$(cat "$CACHE")"
  fi
}

if (( REFRESH == 0 )) && cache_valid; then
  emit_cache_or_filtered
  exit 0
fi

# Sanitise any field destined for the PSV output. Strips:
#   - NUL + C0 controls (BEL, BS, VT, FF, SI/SO, ESC, ...) — kills ANSI escapes
#   - DEL (0x7F)
# Then collapses LF/CR/TAB to single space. Finally rewrites `|` to `/` so it
# cannot fake a field delimiter, and squeezes repeated spaces.
#
# NOTE: bytes 0x80-0x9F are NOT stripped, even though they're nominally C1
# controls, because in UTF-8 every multi-byte codepoint contains continuation
# bytes in that range. Stripping them would corrupt every non-ASCII string
# (e.g. em-dash `—` = E2 80 94). Raw single-byte C1 escapes only appear in
# legacy 8-bit-encoded text, which is outside the scope of SKILL.md frontmatter.
# Downstream consumers must use a UTF-8-safe terminal/parser anyway.
#
# Applied to name, source, and description so a hostile SKILL.md cannot inject
# extra rows or hijack downstream parsers with ASCII control bytes.
sanitize() {
  printf '%s' "$1" \
    | LC_ALL=C tr '\n\r\t' '   ' \
    | LC_ALL=C tr -d '\000-\010\013-\037\177' \
    | tr '|' '/' \
    | tr -s ' '
}

# Extract a single frontmatter field (scalar or folded/literal block).
# Args: <path> <field-name>. `field` is hardcoded to safe identifiers
# (name / description / when_to_use) so awk-regex injection is not possible.
extract_field() {
  local path="$1" field="$2"
  # Single-pass awk: BOM strip + CRLF strip + frontmatter field extract.
  # Earlier two-stage `awk | tr | awk` design caused SIGPIPE storms when
  # stage-2 `exit`d after finding the field — pipefail then propagated the
  # 141 up through `desc=$(extract_field ...)` and aborted the whole scan.
  # Octal byte literals (`\357\273\277`) work on GNU + BSD + BusyBox awk;
  # the `\xNN` hex form is rejected by BusyBox sed/awk.
  LC_ALL=C awk -v field="$field" '
    BEGIN { fm=0; mode=0 }
    NR==1 && length($0)>=3 && substr($0,1,3)=="\357\273\277" { $0=substr($0,4) }
    { sub(/\r$/, "") }
    /^---[[:space:]]*$/ { fm++; if (fm==2) exit; next }
    fm!=1 { next }
    {
      if ($0 ~ "^" field ":[[:space:]]*[|>][-+0-9]*[[:space:]]*$") { mode=1; next }
      if ($0 ~ "^" field ":") {
        sub("^" field ":[[:space:]]*","");
        if (! ($0 ~ /^["'"'"']/)) {
          sub(/[[:space:]]+#.*$/, "");
        }
        gsub(/^["'"'"']|["'"'"']$/,"");
        print; exit
      }
      if (mode && /^[a-zA-Z_][a-zA-Z0-9_.-]*:/) { exit }
      if (mode) { gsub(/^[[:space:]]+/,""); printf "%s ", $0 }
    }
  ' "$path"
}

emit() {
  local path="$1" raw_source="$2"
  [[ -f "$path" && -r "$path" ]] || return 0
  local name desc when full source disabled
  name=$(sanitize "$(extract_field "$path" "name")")
  name=$(printf '%s' "$name" | cut -c1-128)
  [[ -z "$name" ]] && return 0
  # Detect disable-model-invocation: true. Such skills won't be auto-invoked
  # by Claude (per Claude Code skill spec) — they only fire on explicit user
  # /command. Triage needs to know so it can recommend them differently
  # (e.g. as "user-invoke only", not as an auto-routable option).
  disabled=$(extract_field "$path" "disable-model-invocation")
  source=$(sanitize "$raw_source" | cut -c1-80)
  case "$disabled" in
    true|True|TRUE|yes|Yes|YES) source="${source}!disabled" ;;
  esac
  desc=$(extract_field "$path" "description")
  when=$(extract_field "$path" "when_to_use")
  # ASCII separator only — UTF-8 punctuation here would survive sanitize() but
  # complicates downstream consumers that may not be UTF-8-safe.
  if [[ -n "$when" && -n "$desc" ]]; then
    full="$desc -- when: $when"
  elif [[ -n "$when" ]]; then
    full="$when"
  else
    full="$desc"
  fi
  full=$(sanitize "$full" | cut -c1-250)
  printf '%s|%s|%s\n' "$name" "$source" "$full"
}

# find -L: follow symlinks so personal skills installed as
# ~/.claude/skills/<x> -> <somewhere-else>/<x> are scanned.
scan_dir() {
  local root="$1" source="$2"
  [[ -d "$root" ]] || return 0
  while IFS= read -r -d '' f; do
    emit "$f" "$source"
  done < <(find -L "$root" -maxdepth 6 -name SKILL.md -print0 2>/dev/null)
}

# Like scan_dir, but per-file canonicalises every discovered SKILL.md and
# rejects any whose resolved path falls outside $canonical_root. Required for
# plugin scans because `find -L` will follow symlinks INSIDE the confined
# skills/ dir, defeating the top-level confinement (codex round 6).
scan_dir_confined() {
  local root="$1" source="$2" canonical_root="$3"
  [[ -d "$root" ]] || return 0
  local f canonical_dir canonical_f
  while IFS= read -r -d '' f; do
    canonical_dir=$(cd "$(dirname "$f")" 2>/dev/null && pwd -P) || continue
    canonical_f="$canonical_dir/$(basename "$f")"
    if [[ "$canonical_f" == "$canonical_root"/* ]]; then
      emit "$f" "$source"
    fi
  done < <(find -L "$root" -maxdepth 6 -name SKILL.md -print0 2>/dev/null)
}

# Parse installed_plugins.json without jq. Emits one TSV row per plugin entry:
#   <plugin-name>\t<installPath>
# Plugin name = part before '@' in keys like "vercel@claude-plugins-official".
# Manifest array can hold multiple installs per plugin (different versions/scopes);
# emit every installPath inside the array. Schema is officially undocumented;
# downstream code still falls back to a cache walk if this parser misses anything.
parse_installed_plugins() {
  local manifest="$1"
  [[ -f "$manifest" ]] || return 0
  LC_ALL=C awk '
    /^[[:space:]]+"[^"]+@[^"]+":[[:space:]]*\[/ {
      match($0, /"[^"]+@[^"]+"/)
      key = substr($0, RSTART+1, RLENGTH-2)
      sub(/@.*/, "", key)
      cur = key
      next
    }
    cur != "" && /"installPath":[[:space:]]*"/ {
      match($0, /"installPath":[[:space:]]*"[^"]+"/)
      raw = substr($0, RSTART, RLENGTH)
      sub(/^"installPath":[[:space:]]*"/, "", raw)
      sub(/"$/, "", raw)
      print cur "\t" raw
    }
    cur != "" && /^[[:space:]]*\][[:space:]]*,?[[:space:]]*$/ { cur = "" }
  ' "$manifest"
}

# Extract custom skills path(s) from a plugin's plugin.json (if present).
# Per official plugin manifest, `skills` may be a string or a string array
# of paths relative to the plugin root; these ADD to default `skills/`.
emit_plugin_skill_paths() {
  local plugin_root="$1"
  local manifest_path="$plugin_root/plugin.json"
  [[ -f "$manifest_path" ]] || return 0
  # Three forms must all parse:
  #   "skills": "path"                   (string)
  #   "skills": ["a","b"]                (inline array, common case)
  #   "skills": [\n  "a",\n  "b"\n]      (multi-line array)
  # Earlier version (codex round 5) skipped inline arrays — it `next`ed on the
  # opening `[` line, dropping every value. Below processes the rest of the
  # array-open line in-place, then continues into multi-line mode if needed.
  LC_ALL=C awk '
    function emit_strings(s,   v) {
      while (match(s, /"[^"]+"/)) {
        v = substr(s, RSTART+1, RLENGTH-2)
        if (v != "") print v
        s = substr(s, RSTART+RLENGTH)
      }
    }
    /"skills"[[:space:]]*:/ {
      if (match($0, /"skills"[[:space:]]*:[[:space:]]*\[/)) {
        inarr = 1
        rest = substr($0, RSTART+RLENGTH)
        # rest may contain "a","b"...] all on one line
        # split on close-bracket so we only emit array contents
        close_idx = index(rest, "]")
        if (close_idx > 0) {
          emit_strings(substr(rest, 1, close_idx-1))
          inarr = 0
        } else {
          emit_strings(rest)
        }
        next
      }
      if (match($0, /"skills"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
        raw = substr($0, RSTART, RLENGTH)
        sub(/^"skills"[[:space:]]*:[[:space:]]*"/, "", raw)
        sub(/"$/, "", raw)
        print raw
        next
      }
    }
    inarr {
      close_idx = index($0, "]")
      if (close_idx > 0) {
        emit_strings(substr($0, 1, close_idx-1))
        inarr = 0
      } else {
        emit_strings($0)
      }
    }
  ' "$manifest_path"
}

# Confine a candidate skills dir to the plugin root.
# Canonicalises both via `cd && pwd -P` (resolves symlinks) and verifies the
# candidate's canonical path is the root or a descendant. Returns 0 + prints
# canonical path on success; returns 1 (prints nothing) on rejection.
# Applies to BOTH the default `skills/` and every custom plugin.json path —
# a symlinked `skills/` cannot escape the plugin root either.
confine_to_plugin_root() {
  local candidate="$1" canonical_root="$2"
  local canonical
  canonical=$(cd "$candidate" 2>/dev/null && pwd -P) || return 1
  # [[ ... == pattern ]] with the RHS quoted does literal string compare for the
  # non-glob portion. case-pattern matching is fragile if $canonical_root contains
  # glob metacharacters like `[`, `*`, `?` (codex round 3). [[ is shell-safe.
  if [[ "$canonical" == "$canonical_root" || "$canonical" == "$canonical_root"/* ]]; then
    printf '%s' "$canonical"
    return 0
  fi
  return 1
}

# Walk a plugin install root: default `skills/` + any custom plugin.json paths.
# Both paths are confined to the plugin root (canonical pwd -P prefix match)
# so a hostile or careless plugin cannot make the scanner walk arbitrary dirs.
walk_plugin_root() {
  local plugin_root="$1" label="$2"
  [[ -d "$plugin_root" ]] || return 0
  local canonical_root canonical
  canonical_root=$(cd "$plugin_root" 2>/dev/null && pwd -P) || return 0

  # Default skills/ — must also be confined (codex round 2: symlinked skills/
  # was previously the one unguarded path). Uses scan_dir_confined so per-file
  # canonical paths are also checked — prevents a symlink trap inside skills/
  # from escaping the plugin root via find -L (codex round 6).
  if [[ -d "$plugin_root/skills" ]]; then
    if canonical=$(confine_to_plugin_root "$plugin_root/skills" "$canonical_root"); then
      scan_dir_confined "$canonical" "$label" "$canonical_root"
    fi
  fi

  # Custom skills paths from plugin.json
  local rel abs
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    case "$rel" in
      *..*) continue ;;   # any `..` segment — reject before resolving
      /*)   continue ;;   # absolute paths not allowed by the plugin manifest spec
    esac
    abs="$plugin_root/$rel"
    [[ -d "$abs" ]] || continue
    if canonical=$(confine_to_plugin_root "$abs" "$canonical_root"); then
      scan_dir_confined "$canonical" "$label" "$canonical_root"
    fi
  done < <(emit_plugin_skill_paths "$plugin_root")
}

# Newline-delimited set membership (safe for paths containing `|`, spaces,
# colons, or any non-newline byte — only `\n` is reserved as a separator).
path_seen() {
  local needle="$1" hay="$2"
  printf '%s' "$hay" | grep -Fx -- "$needle" >/dev/null 2>&1
}

TMP_OUT="$(mktemp "${CACHE}.XXXXXX")"
trap 'rm -f "$TMP_OUT"' EXIT INT TERM

# Pre-scan fingerprint — must match the post-scan fingerprint, otherwise a
# SKILL.md / plugin.json / installed_plugins.json was edited DURING the scan
# and the cache we're about to publish is already stale. In that case, emit
# the scanned result for the current caller but do NOT publish to cache.
PRE_FP=$(disk_skill_fingerprint)

manifest="$HOME/.claude/plugins/installed_plugins.json"
seen_plugin_paths=""

# Project roots: include git-root, cwd, and (for monorepos) every nested
# `.claude/skills` directory below the project root.
project_roots=()
if [[ -n "$git_root_for_key" ]]; then
  project_roots+=("$git_root_for_key/.claude/skills")
  while IFS= read -r -d '' nested; do
    case "$nested" in "$git_root_for_key/.claude/skills") continue ;; esac
    project_roots+=("$nested")
  done < <(find -L "$git_root_for_key" -maxdepth 5 -type d -path '*/.claude/skills' -print0 2>/dev/null)
fi
project_roots+=("$PWD/.claude/skills")

{
  # Personal
  scan_dir "$HOME/.claude/skills" "personal"

  # Plugins via authoritative manifest
  if [[ -f "$manifest" ]]; then
    while IFS=$'\t' read -r pname ppath; do
      [[ -n "$pname" && -n "$ppath" ]] || continue
      walk_plugin_root "$ppath" "plugin:$pname"
      seen_plugin_paths="${seen_plugin_paths}${ppath}"$'\n'
    done < <(parse_installed_plugins "$manifest")
  fi

  # Official ${CLAUDE_PLUGIN_DATA} root
  if [[ -d "$HOME/.claude/plugins/data" ]]; then
    for data_root in "$HOME"/.claude/plugins/data/*/; do
      [[ -d "$data_root" ]] || continue
      d_trim="${data_root%/}"
      path_seen "$d_trim" "$seen_plugin_paths" && continue
      walk_plugin_root "$d_trim" "plugin:$(basename "$d_trim")"
      seen_plugin_paths="${seen_plugin_paths}${d_trim}"$'\n'
    done
  fi

  # Plugin cache fallback
  if [[ -d "$HOME/.claude/plugins/cache" ]]; then
    for version_dir in "$HOME"/.claude/plugins/cache/*/*/*/; do
      [[ -d "$version_dir" ]] || continue
      v_trim="${version_dir%/}"
      path_seen "$v_trim" "$seen_plugin_paths" && continue
      plugin_dir="${v_trim%/*}"
      pname="${plugin_dir##*/}"
      walk_plugin_root "$v_trim" "plugin:$pname"
      seen_plugin_paths="${seen_plugin_paths}${v_trim}"$'\n'
    done
  fi

  # Marketplace walk for uncached plugin trees
  if [[ -d "$HOME/.claude/plugins/marketplaces" ]]; then
    for mkt_root in "$HOME"/.claude/plugins/marketplaces/*/; do
      [[ -d "$mkt_root" ]] || continue
      scan_dir "$mkt_root" "plugin-mkt:$(basename "$mkt_root")"
    done
  fi

  # Project roots, deduped
  seen_project_paths=""
  for pr in "${project_roots[@]}"; do
    path_seen "$pr" "$seen_project_paths" && continue
    seen_project_paths="${seen_project_paths}${pr}"$'\n'
    scan_dir "$pr" "project"
  done

  # User-configured extras
  for er in "${extra_roots[@]:-}"; do
    [[ -n "$er" ]] || continue
    scan_dir "$er" "extra"
  done
} | awk -F'|' '
    # Dedup by (name|source); keeps first description per pair.
    { key = $1 "|" $2; if (!(key in seen)) { seen[key]=1; print } }
  ' | sort > "$TMP_OUT"

POST_FP=$(disk_skill_fingerprint)
if [[ "$PRE_FP" == "$POST_FP" ]]; then
  # Atomic publish: write fingerprint sidecar to a tmpfile + atomic rename
  # so a partial-write crash can't leave the fingerprint out of sync with
  # the cache file. Then atomic-rename the cache itself.
  TMP_FP="$(mktemp "${CACHE_FP}.XXXXXX")"
  printf '%s\n' "$POST_FP" > "$TMP_FP"
  mv -f "$TMP_OUT" "$CACHE"
  mv -f "$TMP_FP" "$CACHE_FP"
  trap - EXIT INT TERM
  emit_cache_or_filtered
else
  # Disk changed mid-scan. The result we have is already stale relative to
  # disk; emitting it is fine for this caller, but caching it would lock in
  # bad data for everyone else. Best-effort: emit + bail without publish.
  trap - EXIT INT TERM
  if (( ${#FILTERS[@]} == 0 )) && (( BRIEF == 0 )) && (( LIMIT == 0 )); then
    cat "$TMP_OUT"
  else
    apply_output_filters "$(cat "$TMP_OUT")"
  fi
  rm -f "$TMP_OUT"
fi
