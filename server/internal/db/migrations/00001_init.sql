-- +goose Up

CREATE TABLE bank (
  id          TEXT PRIMARY KEY,
  title       TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  created_at  INTEGER NOT NULL
);

CREATE TABLE document (
  id           TEXT PRIMARY KEY,
  bank_id      TEXT NOT NULL REFERENCES bank(id),
  title        TEXT NOT NULL,
  source_path  TEXT NOT NULL,
  content      TEXT NOT NULL,
  content_hash TEXT NOT NULL,
  status       TEXT NOT NULL CHECK (status IN ('imported','chunking','generating','review','failed')),
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL,
  UNIQUE (bank_id, source_path)
);

CREATE TABLE chunk (
  id           TEXT PRIMARY KEY,
  document_id  TEXT NOT NULL REFERENCES document(id),
  seq          INTEGER NOT NULL,
  heading_path TEXT NOT NULL,
  text         TEXT NOT NULL,
  content_hash TEXT NOT NULL,
  status       TEXT NOT NULL CHECK (status IN ('active','stale','removed')),
  generated_at INTEGER,                          -- NULL = questions not generated yet
  UNIQUE (document_id, content_hash)
);
CREATE INDEX idx_chunk_doc ON chunk(document_id, status, seq);

CREATE TABLE question (
  id                 TEXT PRIMARY KEY,
  bank_id            TEXT NOT NULL REFERENCES bank(id),
  chunk_id           TEXT REFERENCES chunk(id),
  type               TEXT NOT NULL CHECK (type IN ('single','multi','judge','fill')),
  stem               TEXT NOT NULL,
  options            TEXT NOT NULL DEFAULT '[]',   -- JSON array of strings
  answer             TEXT NOT NULL,                -- JSON array of option indexes, e.g. [2]
  explanation        TEXT NOT NULL DEFAULT '',
  difficulty         INTEGER NOT NULL DEFAULT 3 CHECK (difficulty BETWEEN 1 AND 5),
  tags               TEXT NOT NULL DEFAULT '[]',   -- JSON array of strings
  source_quote       TEXT NOT NULL,
  status             TEXT NOT NULL CHECK (status IN
                       ('draft','validated','needs_review','rejected','published','stale','retired')),
  review_note        TEXT NOT NULL DEFAULT '',
  content_hash       TEXT NOT NULL,
  gen_model          TEXT NOT NULL DEFAULT '',
  gen_prompt_version TEXT NOT NULL DEFAULT '',
  flag_count         INTEGER NOT NULL DEFAULT 0,
  sync_seq           INTEGER,
  created_at         INTEGER NOT NULL,
  updated_at         INTEGER NOT NULL
);
CREATE INDEX idx_question_sync ON question(sync_seq);
CREATE INDEX idx_question_bank_status ON question(bank_id, status);
CREATE INDEX idx_question_chunk ON question(chunk_id);
CREATE INDEX idx_question_hash ON question(bank_id, content_hash);

CREATE TABLE attempt (
  id          TEXT PRIMARY KEY,
  question_id TEXT NOT NULL REFERENCES question(id),
  device_id   TEXT NOT NULL,
  answer      TEXT NOT NULL,
  is_correct  INTEGER NOT NULL,
  duration_ms INTEGER,
  answered_at INTEGER NOT NULL,
  received_at INTEGER NOT NULL
);
CREATE INDEX idx_attempt_question ON attempt(question_id);

CREATE TABLE question_state (
  question_id TEXT PRIMARY KEY REFERENCES question(id),
  fsrs        TEXT,
  due_at      INTEGER,
  favorite    INTEGER NOT NULL DEFAULT 0,
  wrong_count INTEGER NOT NULL DEFAULT 0,
  updated_at  INTEGER NOT NULL
);

CREATE TABLE sync_counter (
  id    INTEGER PRIMARY KEY CHECK (id = 1),
  value INTEGER NOT NULL
);
INSERT INTO sync_counter (id, value) VALUES (1, 0);

CREATE TABLE job (
  id           TEXT PRIMARY KEY,
  type         TEXT NOT NULL,
  document_id  TEXT NOT NULL DEFAULT '',
  payload      TEXT NOT NULL,
  status       TEXT NOT NULL CHECK (status IN ('pending','running','done','failed')),
  attempts     INTEGER NOT NULL DEFAULT 0,
  max_attempts INTEGER NOT NULL DEFAULT 3,
  run_at       INTEGER NOT NULL,
  lease_until  INTEGER,
  last_error   TEXT NOT NULL DEFAULT '',
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL
);
CREATE INDEX idx_job_pick ON job(status, run_at);
CREATE INDEX idx_job_doc ON job(document_id, status);

CREATE TABLE llm_call_log (
  id            TEXT PRIMARY KEY,
  job_id        TEXT NOT NULL DEFAULT '',
  role          TEXT NOT NULL,
  provider      TEXT NOT NULL,
  model         TEXT NOT NULL,
  input_tokens  INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0,
  cached_tokens INTEGER NOT NULL DEFAULT 0,
  latency_ms    INTEGER NOT NULL DEFAULT 0,
  ok            INTEGER NOT NULL,
  error         TEXT NOT NULL DEFAULT '',
  created_at    INTEGER NOT NULL
);
CREATE INDEX idx_llm_call_created ON llm_call_log(created_at);

-- +goose Down
DROP TABLE llm_call_log;
DROP TABLE job;
DROP TABLE sync_counter;
DROP TABLE question_state;
DROP TABLE attempt;
DROP TABLE question;
DROP TABLE chunk;
DROP TABLE document;
DROP TABLE bank;
