-- name: ListSyncQuestions :many
SELECT * FROM question
WHERE sync_seq > sqlc.arg(since)
ORDER BY sync_seq ASC
LIMIT sqlc.arg(page_limit);

-- name: ListPublishedQuestionCountsByBank :many
SELECT bank_id, COUNT(*) AS n FROM question WHERE status = 'published' GROUP BY bank_id;

-- name: CurrentSyncSeq :one
SELECT value FROM sync_counter WHERE id = 1;

-- name: InsertAttempt :execrows
INSERT INTO attempt (id, question_id, device_id, answer, is_correct, duration_ms, answered_at, received_at, sync_seq)
SELECT sqlc.arg(id), q.id, sqlc.arg(device_id), sqlc.arg(answer), sqlc.arg(is_correct),
       sqlc.arg(duration_ms), sqlc.arg(answered_at), sqlc.arg(received_at), sqlc.arg(sync_seq)
FROM question q WHERE q.id = sqlc.arg(question_id)
ON CONFLICT(id) DO NOTHING;

-- name: ListAttemptsSince :many
SELECT * FROM attempt
WHERE sync_seq > sqlc.arg(since)
ORDER BY sync_seq ASC
LIMIT sqlc.arg(page_limit);

-- name: UpsertQuestionState :execrows
INSERT INTO question_state (question_id, fsrs, due_at, favorite, wrong_count, updated_at, sync_seq)
SELECT q.id, sqlc.arg(fsrs), sqlc.arg(due_at), sqlc.arg(favorite), sqlc.arg(wrong_count),
       sqlc.arg(updated_at), sqlc.arg(sync_seq)
FROM question q WHERE q.id = sqlc.arg(question_id)
ON CONFLICT(question_id) DO UPDATE SET
  fsrs = excluded.fsrs, due_at = excluded.due_at, favorite = excluded.favorite,
  wrong_count = excluded.wrong_count, updated_at = excluded.updated_at, sync_seq = excluded.sync_seq
WHERE excluded.updated_at > question_state.updated_at;

-- name: ListStatesSince :many
SELECT * FROM question_state
WHERE sync_seq > sqlc.arg(since)
ORDER BY sync_seq ASC
LIMIT sqlc.arg(page_limit);

-- name: BumpQuestionFlag :one
UPDATE question SET flag_count = flag_count + 1, updated_at = ?
WHERE id = ? AND status = 'published'
RETURNING flag_count;

-- name: UpsertQuizSession :execrows
INSERT INTO quiz_session (scope, data, updated_at, device_id, sync_seq)
VALUES (sqlc.arg(scope), sqlc.narg(data), sqlc.arg(updated_at), sqlc.arg(device_id), sqlc.arg(sync_seq))
ON CONFLICT(scope) DO UPDATE SET
  data = excluded.data, updated_at = excluded.updated_at,
  device_id = excluded.device_id, sync_seq = excluded.sync_seq
WHERE excluded.updated_at > quiz_session.updated_at;

-- name: ListQuizSessionsSince :many
SELECT * FROM quiz_session
WHERE sync_seq > sqlc.arg(since)
ORDER BY sync_seq ASC
LIMIT sqlc.arg(page_limit);

-- name: InsertExam :execrows
INSERT INTO exam (id, bank_id, title, finished_at, total, correct, answered, percent, passed,
                  limit_sec, used_ms, device_id, items, sync_seq)
VALUES (sqlc.arg(id), sqlc.arg(bank_id), sqlc.arg(title), sqlc.arg(finished_at), sqlc.arg(total),
        sqlc.arg(correct), sqlc.arg(answered), sqlc.arg(percent), sqlc.arg(passed),
        sqlc.narg(limit_sec), sqlc.arg(used_ms), sqlc.arg(device_id), sqlc.arg(items), sqlc.arg(sync_seq))
ON CONFLICT(id) DO NOTHING;

-- name: ListExamsSince :many
SELECT * FROM exam
WHERE sync_seq > sqlc.arg(since)
ORDER BY sync_seq ASC
LIMIT sqlc.arg(page_limit);
