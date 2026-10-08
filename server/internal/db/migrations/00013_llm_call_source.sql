-- +goose Up

-- The apps call the AI-explanation model themselves and report what each call cost, so the call log
-- now holds two kinds of rows. source says who made the call: 'server' (the pipeline and the
-- assistant, the only rows the daily token budget counts) or 'client' (an app). device_id and ref_id
-- (the question explained) are filled for client rows. estimated marks token counts the app had to
-- guess because the endpoint did not report any.
ALTER TABLE llm_call_log ADD COLUMN source TEXT NOT NULL DEFAULT 'server';
ALTER TABLE llm_call_log ADD COLUMN device_id TEXT NOT NULL DEFAULT '';
ALTER TABLE llm_call_log ADD COLUMN ref_id TEXT NOT NULL DEFAULT '';
ALTER TABLE llm_call_log ADD COLUMN estimated INTEGER NOT NULL DEFAULT 0;
CREATE INDEX idx_llm_call_source ON llm_call_log(source, created_at);

-- +goose Down
DROP INDEX idx_llm_call_source;
ALTER TABLE llm_call_log DROP COLUMN estimated;
ALTER TABLE llm_call_log DROP COLUMN ref_id;
ALTER TABLE llm_call_log DROP COLUMN device_id;
ALTER TABLE llm_call_log DROP COLUMN source;
