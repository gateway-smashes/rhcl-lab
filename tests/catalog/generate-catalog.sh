#!/bin/sh
# Build catalog.json by scanning $REQS_DIR for one self-contained directory
# per walkthrough. Each item directory holds a README.md (with YAML
# front-matter: title, summary, category, status) and, optionally, an
# interactive index.html.
#
#   <item>/README.md    -> title / summary / category / status (front-matter)
#   <item>/index.html   -> interactive page (optional)
#
# The card's title, description, category and status all come from the
# README front-matter, so the catalog is decoupled from directory names —
# rename an item freely and the card follows.
set -eu

REQS_DIR="${REQS_DIR:-/usr/share/nginx/html/reqs}"
OUT="${OUT:-/usr/share/nginx/html/catalog.json}"

# Directories that are tooling, not walkthroughs.
SKIP_DIRS="catalog templates k6 postman"

if [ ! -d "$REQS_DIR" ]; then
  echo "[catalog] $REQS_DIR does not exist; writing empty catalog" >&2
  printf '[]\n' > "$OUT"
  exit 0
fi

esc() { printf '%s' "$1" | sed 's|\\|\\\\|g; s|"|\\"|g'; }

# fm <file> <key> — read a scalar field from the README YAML front-matter.
fm() {
  [ -f "$1" ] || return 0
  awk -v k="$2" '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---"  { exit }
    infm {
      idx=index($0,":")
      if (idx>0) {
        key=substr($0,1,idx-1)
        gsub(/^[ \t]+|[ \t]+$/,"",key)
        if (key==k) {
          val=substr($0,idx+1)
          gsub(/^[ \t]+|[ \t]+$/,"",val)
          sub(/^"/,"",val); sub(/"$/,"",val)
          print val; exit
        }
      }
    }
  ' "$1"
}

# Collect item ids (directory basenames) that carry a README.md or index.html.
# `getting-started` is forced to the top; everything else is alphabetical.
skip_match() {
  for s in $SKIP_DIRS; do [ "$1" = "$s" ] && return 0; done
  return 1
}

rest=$(
  for d in "$REQS_DIR"/*/; do
    [ -d "$d" ] || continue
    id=$(basename "$d")
    skip_match "$id" && continue
    [ "$id" = "getting-started" ] && continue
    [ -f "${d}README.md" ] || [ -f "${d}index.html" ] || continue
    printf '%s\n' "$id"
  done | sort -u
)
ids=""
[ -d "$REQS_DIR/getting-started" ] && ids="getting-started"
ids=$(printf '%s\n%s\n' "$ids" "$rest" | grep -v '^$')

count=0
{
  printf '['
  first=1
  for id in $ids; do
    dir="$REQS_DIR/$id"
    readme="$dir/README.md"
    page=""
    doc=""
    title=""
    desc=""
    category=""
    status=""

    [ -f "$dir/index.html" ] && page="reqs/$id/index.html"
    [ -f "$readme" ] && doc="reqs/$id/README.md"

    # Preferred source: README front-matter.
    title=$(fm "$readme" title)
    desc=$(fm "$readme" summary)
    category=$(fm "$readme" category)
    status=$(fm "$readme" status)

    # Fallbacks for items not yet migrated to front-matter.
    if [ -z "$title" ] && [ -n "$page" ]; then
      title=$(grep -m1 -oE '<title>[^<]+</title>' "$dir/index.html" 2>/dev/null \
                | sed -e 's|<title>||' -e 's|</title>||' || true)
    fi
    if [ -z "$title" ] && [ -f "$readme" ]; then
      title=$(grep -m1 -E '^#+[[:space:]]+.+' "$readme" 2>/dev/null \
                | sed -E 's/^#+[[:space:]]*//' || true)
    fi
    if [ -z "$desc" ] && [ -f "$readme" ]; then
      desc=$(grep -m1 -E '^[A-Za-z0-9*_].+' "$readme" 2>/dev/null \
               | sed -E 's/\*\*([^*]+)\*\*/\1/g; s/`([^`]+)`/\1/g' || true)
    fi
    [ -z "$title" ] && title="$id"

    case "$status" in
      done|in-progress|partial|blocked|not-started) ;;
      *) status="not-started" ;;
    esac

    title_esc=$(esc "$title")
    desc_esc=$(esc "$desc")
    category_esc=$(esc "$category")

    [ $first -eq 0 ] && printf ','
    printf '{"id":"%s","title":"%s","description":"%s","status":"%s"' \
      "$id" "$title_esc" "$desc_esc" "$status"
    [ -n "$category" ] && printf ',"category":"%s"' "$category_esc"
    [ -n "$page" ] && printf ',"page":"%s"' "$page"
    [ -n "$doc" ]  && printf ',"doc":"%s"'  "$doc"
    printf '}'

    first=0
    count=$((count + 1))
  done
  printf ']\n'
} > "$OUT"

echo "[catalog] wrote $OUT ($count entries)"
