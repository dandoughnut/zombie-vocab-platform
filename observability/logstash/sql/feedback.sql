-- Incremental feedback export for Logstash (pipeline/feedback.conf).
-- created_at drives :sql_last_value tracking; created_iso is the same instant
-- as an ISO-8601 string for Logstash's date filter. user_id is deliberately
-- not selected.
SELECT id::text AS id,
       category,
       message,
       app_version,
       platform,
       created_at,
       to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_iso
FROM zombie_vocab.feedback
WHERE created_at > :sql_last_value
ORDER BY created_at
