#!/usr/bin/env bash
# claude-red installer
# Copies offensive security skills into a Claude skills directory.
#
# Skills are installed flat as <target>/<skill-name>/SKILL.md (category
# subfolders from Skills/<category>/<skill>/ are dropped) because Claude
# Code's local skill scanner only auto-discovers skills one level deep.
#
# Usage:
#   ./install.sh                                # interactive (asks for target)
#   ./install.sh --target ~/.claude/skills      # explicit target
#   ./install.sh --category web                 # one category only
#   ./install.sh --target DIR --category web    # combined
#   ./install.sh --list                         # list available categories
#   ./install.sh --dry-run                      # show what would be copied
#
# Default target: ~/.claude/skills/claude-red

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$SCRIPT_DIR/Skills"
DEFAULT_TARGET="${HOME}/.claude/skills/claude-red"

TARGET=""
CATEGORY=""
DRY_RUN=0
LIST_ONLY=0

usage() {
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

list_categories() {
  echo "Available categories:"
  for d in "$SKILLS_DIR"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    count=$(find "$d" -name SKILL.md | wc -l | tr -d ' ')
    printf "  %-20s %s skill(s)\n" "$name" "$count"
  done
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target)   TARGET="$2"; shift 2 ;;
    --category) CATEGORY="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --list)     LIST_ONLY=1; shift ;;
    -h|--help)  usage 0 ;;
    *)          echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

if [ "$LIST_ONLY" -eq 1 ]; then
  list_categories
  exit 0
fi

if [ ! -d "$SKILLS_DIR" ]; then
  echo "Error: Skills directory not found at $SKILLS_DIR" >&2
  exit 1
fi

# Interactive prompt if no target given
if [ -z "$TARGET" ]; then
  if [ -t 0 ]; then
    read -r -p "Install target [$DEFAULT_TARGET]: " TARGET || true
  fi
  TARGET="${TARGET:-$DEFAULT_TARGET}"
fi

# Validate category if specified
if [ -n "$CATEGORY" ]; then
  if [ ! -d "$SKILLS_DIR/$CATEGORY" ]; then
    echo "Error: Category '$CATEGORY' not found." >&2
    echo "" >&2
    list_categories >&2
    exit 1
  fi
  SOURCE="$SKILLS_DIR/$CATEGORY"
else
  SOURCE="$SKILLS_DIR"
fi
DEST="$TARGET"

echo "Source:  $SOURCE"
echo "Target:  $DEST  (flat: <skill-name>/SKILL.md, no category subfolder)"
echo

# Collect source SKILL.md paths and check for skill-name collisions before
# touching the filesystem (two categories should never share a skill name,
# but a flat target can't tell two same-named skills apart).
skill_paths=()
while IFS= read -r -d '' path; do
  skill_paths+=("$path")
done < <(find "$SOURCE" -name SKILL.md -print0 | sort -z)

declare -A seen
for path in "${skill_paths[@]}"; do
  skill_name="$(basename "$(dirname "$path")")"
  if [ -n "${seen[$skill_name]:-}" ]; then
    echo "Error: skill name '$skill_name' appears under multiple categories (${seen[$skill_name]} and $path)." >&2
    echo "Flat install can't disambiguate them — rename one of the skill directories." >&2
    exit 1
  fi
  seen[$skill_name]="$path"
done

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[dry-run] Would copy:"
  for path in "${skill_paths[@]}"; do
    skill_name="$(basename "$(dirname "$path")")"
    echo "  $DEST/$skill_name/SKILL.md"
  done
  exit 0
fi

for path in "${skill_paths[@]}"; do
  skill_name="$(basename "$(dirname "$path")")"
  mkdir -p "$DEST/$skill_name"
  cp "$path" "$DEST/$skill_name/SKILL.md"
done

skill_count=${#skill_paths[@]}
echo
echo "Installed $skill_count skill(s) to $DEST"
echo "Claude should now auto-discover them on next session start."
