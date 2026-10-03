-- name: CreateDocument :one
INSERT INTO document (id, bank_id, title, source_path, content, content_hash, status, created_at, updated_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
RETURNING *;

-- name: GetDocument :one
SELECT * FROM document WHERE id = ?;

-- name: GetDocumentBySourcePath :one
SELECT * FROM document WHERE bank_id = ? AND source_path = ?;

-- name: ListDocuments :many
SELECT * FROM document ORDER BY updated_at DESC;

-- name: UpdateDocumentContent :exec
UPDATE document
SET title = ?, content = ?, content_hash = ?, status = ?, updated_at = ?
WHERE id = ?;

-- name: SetDocumentStatus :exec
UPDATE document SET status = ?, updated_at = ? WHERE id = ?;

-- name: DocumentQuestionCounts :many
SELECT c.document_id AS document_id, q.status AS status, COUNT(*) AS n
FROM question q
JOIN chunk c ON c.id = q.chunk_id
GROUP BY c.document_id, q.status;

-- name: SetDocumentTitle :exec
UPDATE document SET title = ?, updated_at = ? WHERE id = ?;
