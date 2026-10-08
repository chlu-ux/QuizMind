-- +goose Up

-- Conversations with the study assistant, kept on the server so every device sees them. Only what
-- the learner saw is stored (words, the lookup lines, the drafts, a remark about how the answer
-- ended); the model's tool calls and reasoning are not, so a conversation carried on later starts
-- from its text, exactly as before history existed. Deleting a conversation deletes its messages
-- in one transaction (foreign keys are not relied on).
CREATE TABLE agent_conversation (
  id          TEXT PRIMARY KEY,           -- chosen by the app (a ULID); drafts and the usage log use it too
  mode        TEXT NOT NULL CHECK (mode IN ('learn','create')),
  title       TEXT NOT NULL DEFAULT '',   -- the first words of the first question
  device_id   TEXT NOT NULL DEFAULT '',   -- the device that spoke last; a record, not a restriction
  bank_id     TEXT NOT NULL DEFAULT '',
  lesson_id   TEXT NOT NULL DEFAULT '',
  question_id TEXT NOT NULL DEFAULT '',   -- what the learner was looking at when it began
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);
CREATE INDEX idx_agent_conv_updated ON agent_conversation(updated_at DESC);

CREATE TABLE agent_message (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  conversation_id TEXT NOT NULL,
  role            TEXT NOT NULL CHECK (role IN ('user','assistant')),
  text            TEXT NOT NULL DEFAULT '',
  tools           TEXT NOT NULL DEFAULT '[]',   -- [{id,label,status}] for the lookup lines
  draft_ids       TEXT NOT NULL DEFAULT '[]',   -- questions this answer wrote
  attachment_ids  TEXT NOT NULL DEFAULT '[]',   -- files this message carried
  note            TEXT NOT NULL DEFAULT '',     -- stopped / cut short
  error           TEXT NOT NULL DEFAULT '',
  created_at      INTEGER NOT NULL
);
CREATE INDEX idx_agent_msg_conv ON agent_message(conversation_id, id);

-- +goose Down
DROP INDEX idx_agent_msg_conv;
DROP TABLE agent_message;
DROP INDEX idx_agent_conv_updated;
DROP TABLE agent_conversation;
