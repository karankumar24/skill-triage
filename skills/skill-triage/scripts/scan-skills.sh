#!/usr/bin/env bash
# scan-skills.sh — emit name|source|description for every installed skill.
# Source = personal | plugin:<plugin-name> | project
# One line per skill, pipe-delimited, description trimmed to 280 chars.
# Cached for 10 minutes in ${TMPDIR:-/tmp}/skill-triage-cache.$UID.tsv.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scan-skills.sh [--refresh] [--help]

  --refresh    Bust the cache and rescan from disk.
  --help, -h   Show this message.

Scans personal (~/.claude/skills), plugin (~/.claude/plugins/cache/*),
and project (.claude/skills) skill directories for SKILL.md files.
Emits one line per skill: name|source|description.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --refresh|"") ;;
  *) echo "scan-skills.sh: unknown flag: $1" >&2; usage >&2; exit 2 ;;
esac

CACHE_DIR="${TMPDIR:-/tmp}"
CACHE="${CACHE_DIR%/}/skill-triage-cache.${UID:-$(id -u)}.tsv"
TTL=600

if [[ "${1:-}" != "--refresh" && -f "$CACHE" ]]; then
  age=$(( $(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE" 2>/dev/null || echo 0) ))
  if (( age < TTL )); then
    cat "$CACHE"
    exit 0
  fi
fi

emit() {
  local path="$1" source="$2"
  [[ -f "$path" ]] || return 0
  local name desc
  name=$(awk '/^name:/{sub(/^name:[[:space:]]*/,""); print; exit}' "$path")
  desc=$(awk '
    /^description:[[:space:]]*[|>]/ { mode=1; next }
    /^description:/ { sub(/^description:[[:space:]]*/,""); print; exit }
    mode && /^[a-zA-Z_-]+:/ { exit }
    mode { gsub(/^[[:space:]]+/,""); printf "%s ", $0 }
  ' "$path" | tr -s ' ' | cut -c1-280)
  [[ -z "$name" ]] && return 0
  printf '%s|%s|%s\n' "$name" "$source" "$desc"
}

scan_dir() {
  local root="$1" source="$2"
  [[ -d "$root" ]] || return 0
  while IFS= read -r -d '' f; do
    emit "$f" "$source"
  done < <(find "$root" -maxdepth 6 -name SKILL.md -print0 2>/dev/null)
}

TMP_OUT="$(mktemp "${CACHE}.XXXXXX")"
trap 'rm -f "$TMP_OUT"' EXIT

{
  scan_dir "$HOME/.claude/skills" "personal"
  if [[ -d "$HOME/.claude/plugins/cache" ]]; then
    for plugin_root in "$HOME"/.claude/plugins/cache/*/; do
      [[ -d "$plugin_root" ]] || continue
      pname=$(basename "$plugin_root")
      scan_dir "$plugin_root" "plugin:$pname"
    done
  fi
  scan_dir ".claude/skills" "project"
} | sort -u > "$TMP_OUT"

mv -f "$TMP_OUT" "$CACHE"
trap - EXIT
cat "$CACHE"
