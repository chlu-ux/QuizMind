-- +goose Up

-- A question the study assistant wrote in a conversation. The question itself is an ordinary row of
-- question (status 'draft', gen_prompt_version 'agent.*', chunk_id = the section it was written
-- from); this row says which conversation and device it came from and whether a second model
-- double-checked it. A draft is visible only in that chat: it is not synced, not counted and not in
-- the review queue until the learner accepts it (status becomes needs_review).
CREATE TABLE agent_draft (
  question_id     TEXT PRIMARY KEY REFERENCES question(id),
  conversation_id TEXT NOT NULL,
  lesson_id       TEXT NOT NULL,
  device_id       TEXT NOT NULL DEFAULT '',
  verified        INTEGER NOT NULL DEFAULT 0,
  created_at      INTEGER NOT NULL
);
CREATE INDEX idx_agent_draft_conv ON agent_draft(conversation_id);
CREATE INDEX idx_agent_draft_created ON agent_draft(created_at);

-- +goose Down
DROP INDEX idx_agent_draft_created;
DROP INDEX idx_agent_draft_conv;
DROP TABLE agent_draft;
