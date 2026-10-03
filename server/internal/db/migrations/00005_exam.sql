-- +goose Up

-- Finished mock exams. Append-only: an exam never changes after it is handed in, so
-- uploads are idempotent on id. items is the client's per-question record
-- ([{"q": question id, "s": picked option indexes (empty = blank), "c": correct}]) in
-- paper order, which lets any device review the paper later. sync_seq is
-- server-assigned, like on question_state.
CREATE TABLE exam (
  id          TEXT PRIMARY KEY,
  bank_id     TEXT NOT NULL,
  title       TEXT NOT NULL,
  finished_at INTEGER NOT NULL,
  total       INTEGER NOT NULL,
  correct     INTEGER NOT NULL,
  answered    INTEGER NOT NULL,
  percent     INTEGER NOT NULL,
  passed      INTEGER NOT NULL,
  limit_sec   INTEGER,
  used_ms     INTEGER NOT NULL,
  device_id   TEXT NOT NULL DEFAULT '',
  items       TEXT NOT NULL,
  sync_seq    INTEGER NOT NULL
);
CREATE INDEX idx_exam_sync ON exam(sync_seq);

-- +goose Down
DROP INDEX idx_exam_sync;
DROP TABLE exam;
