#!/bin/sh
# Idempotent Kibana bootstrap: imports every *.ndjson in this directory as
# saved objects (data views, saved searches, and any dashboards you export
# from the UI into this folder). Dashboards as code: commit the export, and
# every fresh stack comes up with it.
set -eu

KIBANA_URL="${KIBANA_URL:-http://localhost:5601}"
DIR="$(dirname "$0")"

for f in "$DIR"/*.ndjson; do
  [ -e "$f" ] || continue
  # The import API answers 200 even when objects fail; check the body.
  result=$(curl -fsS -X POST "$KIBANA_URL/api/saved_objects/_import?overwrite=true" \
    -H 'kbn-xsrf: true' --form file=@"$f")
  case "$result" in
    *'"success":true'*) echo "imported: $(basename "$f")" ;;
    *) echo "import failed: $(basename "$f"): $result" >&2; exit 1 ;;
  esac
done
