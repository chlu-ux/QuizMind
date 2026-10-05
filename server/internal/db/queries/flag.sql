-- name: InsertQuestionFlag :exec
INSERT INTO question_flag (id, question_id, reason, created_at)
VALUES (?, ?, ?, ?);

-- name: ListQuestionFlags :many
SELECT * FROM question_flag
WHERE question_id = ?
ORDER BY created_at DESC, id DESC;

-- name: ResolveQuestionFlags :exec
UPDATE question_flag SET resolved_at = ?
WHERE question_id = ? AND resolved_at IS NULL;

-- name: ClearQuestionFlagCount :exec
UPDATE question SET flag_count = 0 WHERE id = ?;

-- name: CountFlaggedQuestions :one
SELECT COUNT(*) FROM question
WHERE flag_count > 0 AND (sqlc.narg(bank_id) IS NULL OR bank_id = sqlc.narg(bank_id));
