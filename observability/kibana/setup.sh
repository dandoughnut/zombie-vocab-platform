#!/bin/sh
# Idempotent Kibana bootstrap: a data view over the Filebeat data stream, then
# every *.ndjson in this directory imported as saved objects. Build dashboards
# in the UI, export them (Stack Management → Saved objects → Export) into
# observability/kibana/, commit, and every fresh stack comes up with them.
set -eu

KIBANA_URL="${KIBANA_URL:-http://localhost:5601}"
DIR="$(dirname "$0")"

curl -fsS -X POST "$KIBANA_URL/api/data_views/data_view" \
  -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
  -d '{"override": true, "data_view": {"id": "zombie-vocab-logs", "name": "Zombie Vocab API logs", "title": "filebeat-*", "timeFieldName": "@timestamp"}}' \
  > /dev/null
echo "data view: zombie-vocab-logs"

for f in "$DIR"/*.ndjson; do
  [ -e "$f" ] || continue
  curl -fsS -X POST "$KIBANA_URL/api/saved_objects/_import?overwrite=true" \
    -H 'kbn-xsrf: true' --form file=@"$f" > /dev/null
  echo "imported: $(basename "$f")"
done
