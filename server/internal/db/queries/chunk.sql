-- name: ListChunksByDocument :many
SELECT * FROM chunk WHERE document_id = ? ORDER BY seq;

-- name: GetChunk :one
SELECT * FROM chunk WHERE id = ?;

-- name: InsertChunk :exec
INSERT INTO chunk (id, document_id, seq, heading_path, text, content_hash, status)
VALUES (?, ?, ?, ?, ?, ?, ?);

-- name: UpdateChunk :exec
UPDATE chunk SET seq = ?, heading_path = ?, status = ? WHERE id = ?;

-- name: ListChunksToGenerate :many
SELECT * FROM chunk
WHERE document_id = ? AND status = 'active' AND generated_at IS NULL
ORDER BY seq;

-- name: MarkChunkGenerated :execrows
UPDATE chunk SET generated_at = ? WHERE id = ? AND generated_at IS NULL;
