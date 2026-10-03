-- +goose Up

-- Attempts get a server-assigned sync_seq so a second device can download what the
-- first one answered (statistics are computed from the attempt log). Existing rows
-- are numbered in arrival order after the current counter value.
ALTER TABLE attempt ADD COLUMN sync_seq INTEGER NOT NULL DEFAULT 0;

UPDATE attempt SET sync_seq = (SELECT value FROM sync_counter WHERE id = 1) + (
  SELECT COUNT(*) FROM attempt a2 WHERE (a2.received_at, a2.id) <= (attempt.received_at, attempt.id)
);
UPDATE sync_counter SET value = value + (SELECT COUNT(*) FROM attempt) WHERE id = 1;

CREATE INDEX idx_attempt_sync ON attempt(sync_seq);

-- +goose Down
DROP INDEX idx_attempt_sync;
ALTER TABLE attempt DROP COLUMN sync_seq;
