-- +goose Up

-- One row per "this question has a problem" report from an app. question.flag_count
-- now counts the reports that are still unresolved; a reviewer resolving them
-- (approve, reject, or "dismiss flags") stamps resolved_at and zeroes the counter.
-- reason is one of wrong_answer | ambiguous | typo | other.
CREATE TABLE question_flag (
  id          TEXT PRIMARY KEY,
  question_id TEXT NOT NULL REFERENCES question(id),
  reason      TEXT NOT NULL DEFAULT 'other',
  created_at  INTEGER NOT NULL,
  resolved_at INTEGER
);
CREATE INDEX idx_flag_question ON question_flag(question_id, resolved_at);

-- +goose Down
DROP INDEX idx_flag_question;
DROP TABLE question_flag;
