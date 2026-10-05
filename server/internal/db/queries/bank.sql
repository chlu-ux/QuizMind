-- name: CreateBank :one
INSERT INTO bank (id, title, description, created_at)
VALUES (?, ?, ?, ?)
RETURNING *;

-- name: GetBank :one
SELECT * FROM bank WHERE id = ?;

-- name: ListBanks :many
SELECT * FROM bank ORDER BY created_at DESC;

-- name: CountPublishedQuestionsByBank :one
SELECT COUNT(*) FROM question WHERE bank_id = ? AND status = 'published';

-- name: BankDocumentStats :many
SELECT bank_id, COUNT(*) AS documents, MAX(updated_at) AS last_updated
FROM document GROUP BY bank_id;
