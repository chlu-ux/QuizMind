-- name: ListAgentQuestions :many
-- Every published question, for the assistant's tools.
SELECT id, bank_id, chunk_id, type, stem, options, answer, explanation, difficulty
FROM question
WHERE status = 'published'
ORDER BY created_at, id;

-- name: ListAttemptOutcomes :many
-- Every answer ever given, oldest first, for the assistant's progress and weak-point tools.
SELECT question_id, is_correct, answered_at FROM attempt ORDER BY answered_at, id;

-- name: InsertAgentDraft :exec
INSERT INTO agent_draft (question_id, conversation_id, lesson_id, device_id, verified, created_at)
VALUES (?, ?, ?, ?, ?, ?);

-- name: GetAgentDraft :one
SELECT d.question_id, d.conversation_id, d.lesson_id, d.device_id, d.verified, d.created_at, q.status
FROM agent_draft d JOIN question q ON q.id = d.question_id
WHERE d.question_id = ?;

-- name: ListAgentDrafts :many
-- The questions of a conversation that are in play: waiting for a decision (older drafts) or adopted.
-- Thrown-away ones are left out.
SELECT q.*, d.conversation_id, d.verified
FROM agent_draft d JOIN question q ON q.id = d.question_id
WHERE d.conversation_id = ? AND q.status IN ('draft', 'needs_review', 'published')
ORDER BY d.created_at, q.id;

-- name: CountAgentDrafts :one
-- How many questions of a conversation are in play, the number the per-conversation cap counts.
SELECT COUNT(*) FROM agent_draft d JOIN question q ON q.id = d.question_id
WHERE d.conversation_id = ? AND q.status IN ('draft', 'needs_review', 'published');

-- name: RetireStaleDrafts :execrows
-- Drafts nobody decided on for a while are taken out of the way. They stay in the table for the record.
UPDATE question SET status = 'retired', review_note = 'auto: draft not handled in time', updated_at = ?
WHERE status = 'draft' AND id IN (SELECT d.question_id FROM agent_draft d WHERE d.created_at < ?);
