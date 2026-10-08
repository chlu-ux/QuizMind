-- name: InsertQuestion :exec
INSERT INTO question (
  id, bank_id, chunk_id, type, stem, options, answer, explanation, difficulty, tags,
  source_quote, status, review_note, content_hash, gen_model, gen_prompt_version,
  created_at, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);

-- name: GetQuestionDetail :one
SELECT q.*,
       COALESCE(c.text, '')         AS chunk_text,
       COALESCE(c.heading_path, '') AS heading_path,
       COALESCE(c.document_id, '')  AS document_id
FROM question q
LEFT JOIN chunk c ON c.id = q.chunk_id
WHERE q.id = ?;

-- name: GetQuestion :one
SELECT * FROM question WHERE id = ?;

-- name: ListQuestions :many
SELECT q.* FROM question q
LEFT JOIN chunk c ON c.id = q.chunk_id
-- Assistant drafts belong to a chat until accepted, so they are listed only when asked for by status.
WHERE (q.status = sqlc.narg(status) OR (sqlc.narg(status) IS NULL AND q.status <> 'draft'))
  AND (sqlc.arg(agent_only) = 0 OR q.gen_prompt_version LIKE 'agent.%')
  AND (sqlc.narg(bank_id) IS NULL OR q.bank_id = sqlc.narg(bank_id))
  AND (sqlc.narg(document_id) IS NULL OR c.document_id = sqlc.narg(document_id))
  AND (sqlc.arg(flagged) = 0 OR q.flag_count > 0)
  AND (sqlc.narg(search) IS NULL
       OR instr(lower(q.stem), lower(sqlc.narg(search))) > 0
       OR instr(lower(q.options), lower(sqlc.narg(search))) > 0
       OR instr(lower(q.explanation), lower(sqlc.narg(search))) > 0)
ORDER BY q.created_at DESC, q.id DESC
LIMIT sqlc.arg(page_limit) OFFSET sqlc.arg(page_offset);

-- name: CountQuestions :one
SELECT COUNT(*) FROM question q
LEFT JOIN chunk c ON c.id = q.chunk_id
-- Assistant drafts belong to a chat until accepted, so they are listed only when asked for by status.
WHERE (q.status = sqlc.narg(status) OR (sqlc.narg(status) IS NULL AND q.status <> 'draft'))
  AND (sqlc.arg(agent_only) = 0 OR q.gen_prompt_version LIKE 'agent.%')
  AND (sqlc.narg(bank_id) IS NULL OR q.bank_id = sqlc.narg(bank_id))
  AND (sqlc.narg(document_id) IS NULL OR c.document_id = sqlc.narg(document_id))
  AND (sqlc.arg(flagged) = 0 OR q.flag_count > 0)
  AND (sqlc.narg(search) IS NULL
       OR instr(lower(q.stem), lower(sqlc.narg(search))) > 0
       OR instr(lower(q.options), lower(sqlc.narg(search))) > 0
       OR instr(lower(q.explanation), lower(sqlc.narg(search))) > 0);

-- name: UpdateQuestionContent :exec
UPDATE question
SET type = ?, stem = ?, options = ?, answer = ?, explanation = ?, difficulty = ?, tags = ?,
    content_hash = ?, updated_at = ?
WHERE id = ?;

-- name: SetQuestionStatus :exec
UPDATE question
SET status = ?, review_note = ?, sync_seq = ?, updated_at = ?
WHERE id = ?;

-- name: ListLiveQuestionsByBank :many
SELECT id, stem, options, content_hash FROM question
WHERE bank_id = ? AND status NOT IN ('rejected','retired');

-- name: ListQuestionIDsByChunk :many
SELECT id, status FROM question
WHERE chunk_id = ? AND status IN ('published','needs_review','validated');

-- name: NextSyncSeq :one
UPDATE sync_counter SET value = value + 1 WHERE id = 1 RETURNING value;

-- name: QuestionStatusCounts :many
SELECT status, COUNT(*) AS n FROM question
WHERE (sqlc.narg(bank_id) IS NULL OR bank_id = sqlc.narg(bank_id))
GROUP BY status;
