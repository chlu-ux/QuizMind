-- name: InsertMedia :exec
INSERT INTO media (id, mime, size, width, height, data, created_at)
VALUES (?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO NOTHING;

-- name: GetMedia :one
SELECT * FROM media WHERE id = ?;

-- name: GetMediaMeta :one
SELECT id, mime, size, width, height, created_at FROM media WHERE id = ?;

-- name: ListMediaIDs :many
SELECT id FROM media WHERE id IN (sqlc.slice('ids'));
