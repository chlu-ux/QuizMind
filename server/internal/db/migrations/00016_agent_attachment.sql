-- +goose Up

-- Files a learner gives the study assistant. A text file is kept as text (the assistant reads it a
-- page at a time); the image columns are there for pictures, which come later. A file belongs to
-- the conversation it was uploaded for, which need not exist yet: the conversation row appears with
-- the first message. message_id stays NULL until a message carries the file, and files nobody sent
-- are removed after a day.
CREATE TABLE agent_attachment (
  id              TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  kind            TEXT NOT NULL CHECK (kind IN ('text','image')),
  name            TEXT NOT NULL,                  -- the file's own name, for display only
  mime            TEXT NOT NULL,
  size            INTEGER NOT NULL,               -- bytes as uploaded
  chars           INTEGER NOT NULL DEFAULT 0,     -- text: characters of the extracted text
  width           INTEGER NOT NULL DEFAULT 0,
  height          INTEGER NOT NULL DEFAULT 0,
  text            TEXT NOT NULL DEFAULT '',       -- text files
  data            BLOB,                           -- images
  message_id      INTEGER,                        -- agent_message.id once sent
  created_at      INTEGER NOT NULL
);
CREATE INDEX idx_agent_att_conv ON agent_attachment(conversation_id);

-- +goose Down
DROP INDEX idx_agent_att_conv;
DROP TABLE agent_attachment;
