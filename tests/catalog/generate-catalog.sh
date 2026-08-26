#!/bin/sh
# Build catalog.json by scanning $REQS_DIR for both:
#   * req*/index.html  -> interactive PoC pages
#   * req*.md          -> the spec/instructions for the requirement
#
# Entries are merged by id, so a requirement that has both is shown as a
# single card with two action links.
set -eu

REQS_DIR="${REQS_DIR:-/usr/share/nginx/html/reqs}"
OUT="${OUT:-/usr/share/nginx/html/catalog.json}"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STATUS_FILE="${STATUS_FILE:-}"

if [ -z "$STATUS_FILE" ]; then
  if [ -f "$SCRIPT_DIR/status.tsv" ]; then
    STATUS_FILE="$SCRIPT_DIR/status.tsv"
  elif [ -f "$REQS_DIR/catalog/status.tsv" ]; then
    STATUS_FILE="$REQS_DIR/catalog/status.tsv"
  else
    STATUS_FILE=""
  fi
fi

if [ ! -d "$REQS_DIR" ]; then
  echo "[catalog] $REQS_DIR does not exist; writing empty catalog" >&2
  printf '[]\n' > "$OUT"
  exit 0
fi

# Collect req ids from directories with index.html and from root-level *.md.
# `getting-started` is included as a special non-req guide — same shape
# (md at root, optional subdir with scripts/manifests) but sorted first so
# it lands on top of the catalog card grid.
ids=$(
  {
    for d in "$REQS_DIR"/req*/; do
      [ -d "$d" ] || continue
      [ -f "${d}index.html" ] || continue
      basename "$d"
    done
    for f in "$REQS_DIR"/req*.md; do
      [ -f "$f" ] || continue
      basename "$f" .md
    done
    # Non-req guides — add any tests/*.md whose basename we want in the
    # catalog beyond the reqXXX pattern.
    for g in getting-started; do
      [ -f "$REQS_DIR/$g.md" ] || continue
      printf '%s\n' "$g"
    done
  } | sort -u
)

esc() { printf '%s' "$1" | sed 's|\\|\\\\|g; s|"|\\"|g'; }
status_for() {
  key="$1"
  if [ -n "$STATUS_FILE" ] && [ -f "$STATUS_FILE" ]; then
    awk -F '	' -v key="$key" '
      $0 !~ /^#/ && $1 == key {
        print $2
        found = 1
        exit
      }
      END { if (!found) print "" }
    ' "$STATUS_FILE"
  fi
}
status_note_for() {
  key="$1"
  if [ -n "$STATUS_FILE" ] && [ -f "$STATUS_FILE" ]; then
    awk -F '	' -v key="$key" '
      $0 !~ /^#/ && $1 == key {
        print $3
        found = 1
        exit
      }
      END { if (!found) print "" }
    ' "$STATUS_FILE"
  fi
}

count=0
{
  printf '['
  first=1
  for id in $ids; do
    page=""
    doc=""
    title=""
    desc=""

    # Interactive page (req*/index.html)
    if [ -f "$REQS_DIR/$id/index.html" ]; then
      page="reqs/$id/index.html"
      title=$(grep -m 1 -oE '<title>[^<]+</title>' "$REQS_DIR/$id/index.html" 2>/dev/null \
                | sed -e 's|<title>||' -e 's|</title>||' || true)
    fi

    # Spec markdown (root req*.md)
    if [ -f "$REQS_DIR/$id.md" ]; then
      doc="reqs/$id.md"
      if [ -z "$title" ]; then
        # First Markdown heading line, strip leading #s and whitespace.
        title=$(grep -m 1 -E '^#+[[:space:]]+.+' "$REQS_DIR/$id.md" 2>/dev/null \
                  | sed -E 's/^#+[[:space:]]*//' || true)
      fi
      if [ -z "$desc" ]; then
        # First non-heading, non-quote, non-list, non-code line.
        desc=$(grep -m 1 -E '^[A-Za-z0-9*_].+' "$REQS_DIR/$id.md" 2>/dev/null \
                 | sed -E 's/\*\*([^*]+)\*\*/\1/g; s/`([^`]+)`/\1/g' || true)
      fi
    fi

    # Fall back to README.md inside the dir for the description.
    if [ -z "$desc" ] && [ -f "$REQS_DIR/$id/README.md" ]; then
      desc=$(grep -m 1 -E '^[A-Za-z0-9*_].+' "$REQS_DIR/$id/README.md" 2>/dev/null || true)
    fi

    [ -z "$title" ] && title="$id"

    req_status=$(status_for "$id")
    case "$req_status" in
      done|partial|blocked|not-started) ;;
      *) req_status="not-started" ;;
    esac
    status_note=$(status_note_for "$id")

    title_esc=$(esc "$title")
    desc_esc=$(esc "$desc")
    status_note_esc=$(esc "$status_note")

    [ $first -eq 0 ] && printf ','
    printf '{"id":"%s","title":"%s","description":"%s","status":"%s"' "$id" "$title_esc" "$desc_esc" "$req_status"
    [ -n "$status_note" ] && printf ',"statusNote":"%s"' "$status_note_esc"
    [ -n "$page" ] && printf ',"page":"%s"' "$page"
    [ -n "$doc" ]  && printf ',"doc":"%s"'  "$doc"
    printf '}'

    first=0
    count=$((count + 1))
  done
  printf ']\n'
} > "$OUT"

echo "[catalog] wrote $OUT ($count entries)"
