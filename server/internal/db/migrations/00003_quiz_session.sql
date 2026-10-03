-- +goose Up

-- One saved quiz per scope (a bank id), so a quiz left on one device can be
-- continued on another. data is the client's progress document and opaque to the
-- server; NULL marks a finished quiz and clears it on every device. Like
-- question_state, rows carry a server-assigned sync_seq so devices can pull what
-- the others changed without trusting each other's clocks.
CREATE TABLE quiz_session (
  scope      TEXT PRIMARY KEY,
  data       TEXT,
  updated_at INTEGER NOT NULL,
  device_id  TEXT NOT NULL DEFAULT '',
  sync_seq   INTEGER NOT NULL
);
CREATE INDEX idx_quiz_session_sync ON quiz_session(sync_seq);

-- +goose Down
DROP INDEX idx_quiz_session_sync;
DROP TABLE quiz_session;
