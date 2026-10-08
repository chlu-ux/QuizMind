-- name: UpsertAgentConversation :exec
-- Creates the conversation, or marks it as just spoken in (its mode and starting context stay as they were).
INSERT INTO agent_conversation (id, mode, device_id, bank_id, lesson_id, question_id, created_at, updated_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET device_id = excluded.device_id, updated_at = excluded.updated_at;

-- name: GetAgentConversation :one
SELECT * FROM agent_conversation WHERE id = ?;

-- name: SetAgentConversationTitle :exec
UPDATE agent_conversation SET title = ? WHERE id = ?;

-- name: TouchAgentConversation :exec
UPDATE agent_conversation SET updated_at = ? WHERE id = ?;

-- name: InsertAgentMessage :one
INSERT INTO agent_message (conversation_id, role, text, tools, draft_ids, attachment_ids, note, error, created_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
RETURNING id;

-- name: ListAgentMessages :many
SELECT * FROM agent_message WHERE conversation_id = ? ORDER BY id;

-- name: ListAgentConversations :many
-- Newest first. Conversations nobody has said anything in yet are not listed.
SELECT c.id, c.mode, c.title, c.bank_id, c.lesson_id, c.question_id, c.updated_at,
       (SELECT COUNT(*) FROM agent_message m WHERE m.conversation_id = c.id) AS message_count,
       (SELECT COUNT(*) FROM agent_draft d JOIN question q ON q.id = d.question_id
         WHERE d.conversation_id = c.id AND q.status = 'draft') AS pending_drafts
FROM agent_conversation c
WHERE c.updated_at < sqlc.arg(before)
  AND (sqlc.narg(mode) IS NULL OR c.mode = sqlc.narg(mode))
  AND EXISTS (SELECT 1 FROM agent_message m WHERE m.conversation_id = c.id)
ORDER BY c.updated_at DESC, c.id DESC
LIMIT sqlc.arg(page_limit);

-- name: ListConversationDrafts :many
-- Every draft of a conversation whatever became of it, so a reopened chat can show the cards as they stand.
SELECT q.*, d.lesson_id AS draft_lesson_id, d.verified
FROM agent_draft d JOIN question q ON q.id = d.question_id
WHERE d.conversation_id = ?
ORDER BY d.created_at, q.id;

-- name: RejectConversationDrafts :execrows
-- Deleting a conversation throws away the drafts nobody decided on; accepted questions are not touched.
UPDATE question SET status = 'rejected', review_note = 'discarded: conversation deleted', updated_at = ?
WHERE status = 'draft' AND id IN (SELECT question_id FROM agent_draft WHERE conversation_id = ?);

-- name: DeleteAgentMessages :exec
DELETE FROM agent_message WHERE conversation_id = ?;

-- name: DeleteAgentConversation :exec
DELETE FROM agent_conversation WHERE id = ?;

-- name: DeleteEmptyAgentConversations :execrows
-- Rows made by an upload or a request that never got as far as a message.
DELETE FROM agent_conversation
WHERE updated_at < ? AND NOT EXISTS (SELECT 1 FROM agent_message m WHERE m.conversation_id = agent_conversation.id);
