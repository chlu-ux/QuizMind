-- name: InsertAgentAttachment :exec
INSERT INTO agent_attachment (id, conversation_id, kind, name, mime, size, chars, width, height, text, data, created_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);

-- name: GetAgentAttachment :one
SELECT * FROM agent_attachment WHERE id = ?;

-- name: ListConversationAttachments :many
-- Without the text and the bytes: this is for lists and checks.
SELECT id, conversation_id, kind, name, mime, size, chars, width, height, message_id, created_at
FROM agent_attachment WHERE conversation_id = ? ORDER BY created_at, id;

-- name: MarkAgentAttachmentSent :execrows
UPDATE agent_attachment SET message_id = ? WHERE id = ? AND conversation_id = ? AND message_id IS NULL;

-- name: DeleteUnsentAgentAttachment :execrows
DELETE FROM agent_attachment WHERE id = ? AND message_id IS NULL;

-- name: DeleteConversationAttachments :exec
DELETE FROM agent_attachment WHERE conversation_id = ?;

-- name: DeleteStaleAgentAttachments :execrows
-- Files uploaded and never sent.
DELETE FROM agent_attachment WHERE message_id IS NULL AND created_at < ?;
