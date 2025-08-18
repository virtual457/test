#!/usr/bin/env bash
set -euo pipefail

# Delete all commits on randomly selected days in a given date range for the current branch.
# - Uses only git and standard UNIX tools (works in Git Bash on Windows).
# - Randomly selects existing commit days in the range with given probability (default 0.2).
# - Rebuilds history by cherry-picking only the commits to keep (linear history only).
# - Supports dry-run mode to preview selection.

usage() {
  cat <<EOF
Usage: $0 --start YYYY-MM-DD --end YYYY-MM-DD [--prob 0.2] [--author-date] [--dry-run]

Options:
  --start DATE       Inclusive start date (YYYY-MM-DD)
  --end DATE         Exclusive end date (YYYY-MM-DD) or inclusive? We treat it exclusive in filters
                     but accept a YYYY-MM-DD and add 1 day internally for convenience.
  --prob P           Probability (0..1) a day with commits is selected for deletion. Default: 0.2
  --author-date      Select days based on author date instead of committer date
  --dry-run          Show selected days and counts only; do not rewrite history

Notes:
  - Operates on the current branch only. Assumes linear history (no merges).
  - Requires a clean working tree.
  - After applying, you'll need to force-push: git push --force-with-lease origin "+$(git rev-parse --abbrev-ref HEAD)"
EOF
}

START=""
END=""
PROB="0.2"
DATE_FIELD="%cd" # or %ad
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start) START="$2"; shift 2 ;;
    --end) END="$2"; shift 2 ;;
    --prob) PROB="$2"; shift 2 ;;
    --author-date) DATE_FIELD="%ad"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$START" || -z "$END" ]]; then
  echo "--start and --end are required" >&2
  usage
  exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Run this script inside a git repository" >&2
  exit 1
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$BRANCH" == "HEAD" ]]; then
  echo "Refusing to run on detached HEAD" >&2
  exit 1
fi

# Ensure clean tree
if [[ -n $(git status --porcelain) ]]; then
  echo "Working tree not clean. Commit/stash changes first." >&2
  exit 1
fi

# Compute END+1 day for git --until filtering since we want inclusive end
END_PLUS=$(date -d "$END + 1 day" +%Y-%m-%d 2>/dev/null || true)
if [[ -z "$END_PLUS" ]]; then
  # Fallback for environments without GNU date -d
  # Try using python for date arithmetic
  END_PLUS=$(python - "$END" <<'PY'
import sys, datetime
d = datetime.date.fromisoformat(sys.argv[1]) + datetime.timedelta(days=1)
print(d.isoformat())
PY
)
fi

TMP_DIR="$(git rev-parse --git-dir)"
DATES_FILE="$TMP_DIR/random_days.txt"
DROP_FILE="$TMP_DIR/drop_shas.txt"
KEEP_FILE="$TMP_DIR/keep_shas.txt"
>"$DATES_FILE"; >"$DROP_FILE"; >"$KEEP_FILE"

# List unique commit days in range for current branch
# Use the selected date field (author or committer) in short YYYY-MM-DD format
git log --since="$START" --until="$END_PLUS" --no-merges --date=short --format="$DATE_FIELD" "$BRANCH" \
  | sort -u > "$DATES_FILE"

TOTAL_DAYS=$(wc -l < "$DATES_FILE" | tr -d ' ')
if [[ "$TOTAL_DAYS" -eq 0 ]]; then
  echo "No commits in range $START..$END on branch $BRANCH"
  exit 0
fi

# Randomly sample ~PROB of these days
SELECTED_DAYS=$(awk -v p="$PROB" 'BEGIN{srand()} { if (rand() < p) print $0 }' "$DATES_FILE")

echo "Days with commits in range: $TOTAL_DAYS"
echo "Selected days (~$PROB):"
if [[ -n "$SELECTED_DAYS" ]]; then
  echo "$SELECTED_DAYS" | sort | xargs -I{} echo "  {}"
else
  echo "  (none)"
fi

# Collect SHAs to drop: those whose selected date equals a selected day
if [[ -n "$SELECTED_DAYS" ]]; then
  # Create an awk set for fast matching
  AWK_SET=$(echo "$SELECTED_DAYS" | awk '{print "d[\""$0"\"]=1"}')
  git log --since="$START" --until="$END_PLUS" --no-merges --date=short --format="%H %cd" "$BRANCH" \
    | awk -v OFS="\t" -v set="$AWK_SET" '
        BEGIN { eval(set) }
        { sha=$1; date=$2; if (d[date]) print sha }
      ' \
    | sort -u > "$DROP_FILE"
fi

DROP_COUNT=$(wc -l < "$DROP_FILE" | tr -d ' ')
echo "Commits marked to delete: $DROP_COUNT"

if [[ "$DRY_RUN" -eq 1 ]]; then
  exit 0
fi

# Build the keep list = all commits (oldest->newest) minus the drop set
git rev-list --reverse "$BRANCH" > "$KEEP_FILE"
if [[ -s "$DROP_FILE" ]]; then
  grep -vx -f "$DROP_FILE" "$KEEP_FILE" > "$KEEP_FILE.tmp" || true
  mv "$KEEP_FILE.tmp" "$KEEP_FILE"
fi

# Create a synthetic root commit from the tree of the original root commit
ROOT=$(git rev-list --max-parents=0 "$BRANCH" | tail -n1)
ROOT_TREE=$(git rev-parse "$ROOT^{tree}")
NEW_ROOT=$(echo "Synthetic root" | git commit-tree "$ROOT_TREE")
NEW_BRANCH="rebuild-$(date +%s)"
git switch -c "$NEW_BRANCH" "$NEW_ROOT" >/dev/null

# Cherry-pick each kept commit in chronological order
if [[ -s "$KEEP_FILE" ]]; then
  while IFS= read -r sha; do
    # Skip the synthetic root we created
    [[ "$sha" == "$ROOT" ]] && continue
    if grep -qx "$sha" "$DROP_FILE" 2>/dev/null; then
      continue
    fi
    git cherry-pick --allow-empty --allow-empty-message -x "$sha" >/dev/null
  done < "$KEEP_FILE"
fi

echo "Rebuilt branch $NEW_BRANCH"
echo "To replace $BRANCH with the rebuilt history, run:"
echo "  git branch -m $BRANCH ${BRANCH}-old"
echo "  git branch -m $NEW_BRANCH $BRANCH"
echo "  git push --force-with-lease origin $BRANCH"


