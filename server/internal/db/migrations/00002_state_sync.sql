-- +goose Up

-- question_state rows get a server-assigned sync_seq so that every device can pull
-- changes made by the others without depending on client clocks.
ALTER TABLE question_state ADD COLUMN sync_seq INTEGER NOT NULL DEFAULT 0;
CREATE INDEX idx_question_state_sync ON question_state(sync_seq);

-- +goose Down
DROP INDEX idx_question_state_sync;
ALTER TABLE question_state DROP COLUMN sync_seq;
