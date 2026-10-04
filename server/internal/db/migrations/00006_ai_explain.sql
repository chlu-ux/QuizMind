-- +goose Up

-- Small key/value store for settings edited in the admin UI. "ai" holds the JSON
-- of the AI-explanation configuration (LLM endpoint, key, app access token).
CREATE TABLE app_setting (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- AI explanations written on the devices, one per question; last writer wins on
-- the client's updated_at (a re-generated explanation replaces the old one).
-- content is Markdown; selected is the JSON array of option indexes the learner
-- had picked when asking (informational). sync_seq is server-assigned, like on
-- question_state.
CREATE TABLE ai_note (
  question_id    TEXT PRIMARY KEY,
  content        TEXT NOT NULL,
  model          TEXT NOT NULL DEFAULT '',
  prompt_version TEXT NOT NULL DEFAULT '',
  selected       TEXT NOT NULL DEFAULT '[]',
  updated_at     INTEGER NOT NULL,
  device_id      TEXT NOT NULL DEFAULT '',
  sync_seq       INTEGER NOT NULL
);
CREATE INDEX idx_ai_note_sync ON ai_note(sync_seq);

-- +goose Down
DROP INDEX idx_ai_note_sync;
DROP TABLE ai_note;
DROP TABLE app_setting;
