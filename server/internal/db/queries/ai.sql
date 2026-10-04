-- name: GetSetting :one
SELECT value FROM app_setting WHERE key = ?;

-- name: PutSetting :exec
INSERT INTO app_setting (key, value) VALUES (?, ?)
ON CONFLICT(key) DO UPDATE SET value = excluded.value;

-- name: UpsertAINote :execrows
INSERT INTO ai_note (question_id, content, model, prompt_version, selected, updated_at, device_id, sync_seq)
SELECT q.id, sqlc.arg(content), sqlc.arg(model), sqlc.arg(prompt_version), sqlc.arg(selected),
       sqlc.arg(updated_at), sqlc.arg(device_id), sqlc.arg(sync_seq)
FROM question q WHERE q.id = sqlc.arg(question_id)
ON CONFLICT(question_id) DO UPDATE SET
  content = excluded.content, model = excluded.model, prompt_version = excluded.prompt_version,
  selected = excluded.selected, updated_at = excluded.updated_at,
  device_id = excluded.device_id, sync_seq = excluded.sync_seq
WHERE excluded.updated_at > ai_note.updated_at;

-- name: ListAINotesSince :many
SELECT * FROM ai_note
WHERE sync_seq > sqlc.arg(since)
ORDER BY sync_seq ASC
LIMIT sqlc.arg(page_limit);

-- name: ListAINotesAdmin :many
SELECT n.question_id, n.content, n.model, n.prompt_version, n.selected, n.updated_at, n.device_id,
       q.bank_id, b.title AS bank_title, q.type, q.stem, q.options, q.answer, q.explanation
FROM ai_note n
JOIN question q ON q.id = n.question_id
JOIN bank b ON b.id = q.bank_id
WHERE (sqlc.narg(bank_id) IS NULL OR q.bank_id = sqlc.narg(bank_id))
  AND (sqlc.narg(search) IS NULL
       OR instr(q.stem, sqlc.narg(search)) > 0 OR instr(n.content, sqlc.narg(search)) > 0)
ORDER BY n.updated_at DESC, n.question_id DESC
LIMIT sqlc.arg(page_limit) OFFSET sqlc.arg(page_offset);

-- name: CountAINotesAdmin :one
SELECT COUNT(*) FROM ai_note n
JOIN question q ON q.id = n.question_id
WHERE (sqlc.narg(bank_id) IS NULL OR q.bank_id = sqlc.narg(bank_id))
  AND (sqlc.narg(search) IS NULL
       OR instr(q.stem, sqlc.narg(search)) > 0 OR instr(n.content, sqlc.narg(search)) > 0);
