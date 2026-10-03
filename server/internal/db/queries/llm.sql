-- name: InsertLLMCall :exec
INSERT INTO llm_call_log (
  id, job_id, role, provider, model, input_tokens, output_tokens, cached_tokens,
  latency_ms, ok, error, created_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);

-- name: SumTokensSince :one
SELECT CAST(COALESCE(SUM(input_tokens + output_tokens), 0) AS INTEGER) AS total
FROM llm_call_log WHERE created_at >= ?;

-- name: UsageByDay :many
SELECT date(created_at / 1000, 'unixepoch') AS day,
       model,
       COUNT(*)                                              AS calls,
       CAST(COALESCE(SUM(input_tokens), 0) AS INTEGER)       AS input_tokens,
       CAST(COALESCE(SUM(output_tokens), 0) AS INTEGER)      AS output_tokens,
       CAST(COALESCE(SUM(cached_tokens), 0) AS INTEGER)      AS cached_tokens,
       CAST(COALESCE(SUM(1 - ok), 0) AS INTEGER)             AS failures
FROM llm_call_log
WHERE created_at >= ?
GROUP BY day, model
ORDER BY day DESC, model;
