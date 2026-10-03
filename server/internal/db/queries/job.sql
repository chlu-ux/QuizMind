-- name: InsertJob :exec
INSERT INTO job (id, type, document_id, payload, status, attempts, max_attempts, run_at, last_error, created_at, updated_at)
VALUES (?, ?, ?, ?, 'pending', 0, ?, ?, '', ?, ?);

-- name: ClaimJob :one
UPDATE job
SET status = 'running', attempts = attempts + 1, lease_until = sqlc.arg(lease_until), updated_at = sqlc.arg(now)
WHERE id = (
  SELECT j.id FROM job j
  WHERE j.status = 'pending' AND j.run_at <= sqlc.arg(now)
  ORDER BY j.run_at, j.created_at
  LIMIT 1
)
RETURNING *;

-- name: CompleteJob :exec
UPDATE job SET status = 'done', lease_until = NULL, last_error = '', updated_at = ? WHERE id = ?;

-- name: FailJob :exec
UPDATE job SET status = 'failed', lease_until = NULL, last_error = ?, updated_at = ? WHERE id = ?;

-- name: RescheduleJob :exec
UPDATE job SET status = 'pending', run_at = ?, lease_until = NULL, last_error = ?, updated_at = ? WHERE id = ?;

-- name: RecoverExpiredJobs :execrows
UPDATE job
SET status = 'pending', lease_until = NULL, updated_at = sqlc.arg(now)
WHERE status = 'running' AND lease_until IS NOT NULL AND lease_until < sqlc.arg(now);

-- name: GetJob :one
SELECT * FROM job WHERE id = ?;

-- name: ListJobs :many
SELECT * FROM job
WHERE (sqlc.narg(status) IS NULL OR status = sqlc.narg(status))
  AND (sqlc.narg(document_id) IS NULL OR document_id = sqlc.narg(document_id))
ORDER BY created_at DESC, id DESC
LIMIT sqlc.arg(page_limit);

-- name: RetryFailedJob :execrows
UPDATE job
SET status = 'pending', attempts = 0, run_at = sqlc.arg(now), last_error = '', updated_at = sqlc.arg(now)
WHERE id = sqlc.arg(id) AND status = 'failed';

-- name: RetryFailedJobsByDocument :execrows
UPDATE job
SET status = 'pending', attempts = 0, run_at = sqlc.arg(now), last_error = '', updated_at = sqlc.arg(now)
WHERE document_id = sqlc.arg(document_id) AND status = 'failed';

-- name: CountJobsByDocumentAndStatus :one
SELECT COUNT(*) FROM job WHERE document_id = ? AND status = ?;

-- name: CountActiveJobsByDocument :one
SELECT COUNT(*) FROM job WHERE document_id = ? AND status IN ('pending','running');

-- name: DeferJob :exec
-- Put a running job back without charging an attempt (e.g. daily budget spent).
UPDATE job
SET status = 'pending', attempts = MAX(attempts - 1, 0), run_at = ?, lease_until = NULL,
    last_error = ?, updated_at = ?
WHERE id = ?;

-- name: SupersedeFailedJobs :exec
-- A re-import regenerates whatever work is still needed, so old failures no
-- longer describe the document's state.
UPDATE job
SET status = 'done', last_error = 'superseded by re-import', updated_at = ?
WHERE document_id = ? AND status = 'failed';
