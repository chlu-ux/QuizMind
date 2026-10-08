-- +goose Up

-- Model providers and models, edited in the admin UI (they used to come from config.yaml and
-- environment variables). A provider is one endpoint and key; a model belongs to a provider, and
-- several models can share one key. Which model plays which role (generator, agent, …) and the call
-- limits live in app_setting ("llm_roles", "llm_limits").
CREATE TABLE llm_provider (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  protocol   TEXT NOT NULL CHECK (protocol IN ('anthropic','openai')),
  base_url   TEXT NOT NULL DEFAULT '',
  api_key    TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE llm_model (
  id          TEXT PRIMARY KEY,
  provider_id TEXT NOT NULL REFERENCES llm_provider(id),
  name        TEXT NOT NULL,                 -- shown in the admin UI
  model       TEXT NOT NULL,                 -- the id sent to the provider
  max_tokens  INTEGER NOT NULL DEFAULT 8000, -- output cap per call
  temperature REAL NOT NULL DEFAULT 0,       -- openai protocol only; 0 = provider default
  effort      TEXT NOT NULL DEFAULT '',      -- anthropic protocol only
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);
CREATE INDEX idx_llm_model_provider ON llm_model(provider_id);

-- +goose Down
DROP INDEX idx_llm_model_provider;
DROP TABLE llm_model;
DROP TABLE llm_provider;
