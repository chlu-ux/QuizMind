-- +goose Up

-- Whether the model can look at pictures. Only the assistant's model needs it: a learner may attach
-- images to a message only when this is on.
ALTER TABLE llm_model ADD COLUMN vision INTEGER NOT NULL DEFAULT 0;

-- +goose Down
ALTER TABLE llm_model DROP COLUMN vision;
