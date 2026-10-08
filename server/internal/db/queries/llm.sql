-- name: InsertLLMCall :exec
INSERT INTO llm_call_log (
  id, job_id, role, provider, model, input_tokens, output_tokens, cached_tokens,
  latency_ms, ok, error, created_at, source, device_id, ref_id, estimated
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);

-- A call an app reports. The app chooses the id, so sending the same report twice counts once.
-- name: InsertClientLLMCall :execrows
INSERT INTO llm_call_log (
  id, job_id, role, provider, model, input_tokens, output_tokens, cached_tokens,
  latency_ms, ok, error, created_at, source, device_id, ref_id, estimated
) VALUES (?, '', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'client', ?, ?, ?)
ON CONFLICT(id) DO NOTHING;

-- The daily budget limits what the server itself spends; calls the apps made are already spent.
-- name: SumTokensSince :one
SELECT CAST(COALESCE(SUM(input_tokens + output_tokens), 0) AS INTEGER) AS total
FROM llm_call_log WHERE created_at >= ? AND source = 'server';

-- name: UsageByDay :many
SELECT date(created_at / 1000, 'unixepoch', 'localtime') AS day,
       source,
       role,
       model,
       COUNT(*)                                              AS calls,
       CAST(COALESCE(SUM(input_tokens), 0) AS INTEGER)       AS input_tokens,
       CAST(COALESCE(SUM(output_tokens), 0) AS INTEGER)      AS output_tokens,
       CAST(COALESCE(SUM(cached_tokens), 0) AS INTEGER)      AS cached_tokens,
       CAST(COALESCE(SUM(1 - ok), 0) AS INTEGER)             AS failures,
       CAST(COALESCE(SUM(estimated), 0) AS INTEGER)          AS estimated_calls
FROM llm_call_log
WHERE created_at >= ?
GROUP BY day, source, role, model
ORDER BY day DESC, source, role, model;

-- name: ListLLMCalls :many
SELECT c.id, c.source, c.role, c.provider, c.model, c.input_tokens, c.output_tokens, c.cached_tokens,
       c.latency_ms, c.ok, c.error, c.created_at, c.device_id, c.ref_id, c.estimated, c.job_id,
       COALESCE(q.stem, '') AS question_stem, COALESCE(b.title, '') AS bank_title
FROM llm_call_log c
LEFT JOIN question q ON q.id = c.ref_id AND c.ref_id <> ''
LEFT JOIN bank b ON b.id = q.bank_id
WHERE c.created_at >= sqlc.arg(since)
  AND (sqlc.narg(source) IS NULL OR c.source = sqlc.narg(source))
  AND (sqlc.narg(role) IS NULL OR c.role = sqlc.narg(role))
  AND (sqlc.narg(failed_only) IS NULL OR c.ok = 0)
ORDER BY c.created_at DESC, c.id DESC
LIMIT sqlc.arg(page_limit) OFFSET sqlc.arg(page_offset);

-- name: CountLLMCalls :one
SELECT COUNT(*) FROM llm_call_log c
WHERE c.created_at >= sqlc.arg(since)
  AND (sqlc.narg(source) IS NULL OR c.source = sqlc.narg(source))
  AND (sqlc.narg(role) IS NULL OR c.role = sqlc.narg(role))
  AND (sqlc.narg(failed_only) IS NULL OR c.ok = 0);
