#!/bin/sh
# Index templates, created before anything writes (Logstash waits on this).
#
# - logs-zombievocab.*-*: the API log data stream. 14-day retention via the
#   data stream lifecycle: logs older than that are deleted by Elasticsearch
#   itself, the same promise the app makes for analytics events.
# - zombievocab-feedback: an English analyzer on the message, so a search for
#   "crash" also finds "crashed" and "crashes".
set -eu

ES="${ELASTICSEARCH_URL:-http://localhost:9200}"

put() {
  curl -fsS -X PUT "$ES/$1" -H 'Content-Type: application/json' -d "$2" > /dev/null
  echo "ok: $1"
}

put _index_template/zombievocab-logs '{
  "index_patterns": ["logs-zombievocab.*-*"],
  "data_stream": {},
  "priority": 500,
  "composed_of": ["logs@mappings", "ecs@mappings"],
  "template": {
    "lifecycle": { "data_retention": "14d" },
    "mappings": {
      "properties": {
        "http": { "properties": {
          "route":    { "type": "keyword" },
          "request":  { "properties": { "id": { "type": "keyword" } } },
          "response": { "properties": { "status_code": { "type": "integer" } } }
        } },
        "event":   { "properties": { "duration_ms": { "type": "float" } } },
        "billing": { "properties": {
          "provider":  { "type": "keyword" },
          "outcome":   { "type": "keyword" },
          "reason":    { "type": "text", "fields": { "keyword": { "type": "keyword" } } },
          "user_hash": { "type": "keyword" }
        } }
      }
    }
  }
}'

put _index_template/zombievocab-feedback '{
  "index_patterns": ["zombievocab-feedback"],
  "priority": 500,
  "template": {
    "settings": { "number_of_replicas": 0 },
    "mappings": {
      "properties": {
        "@timestamp":  { "type": "date" },
        "created_at":  { "type": "date" },
        "message":     { "type": "text", "analyzer": "english" },
        "category":    { "type": "keyword" },
        "platform":    { "type": "keyword" },
        "app_version": { "type": "keyword" }
      }
    }
  }
}'
