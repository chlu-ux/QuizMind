-- +goose Up

-- Time spent on a question after answering it (reading the explanation, asking the AI),
-- on top of duration_ms, which stops at submit. It is filled in when the learner leaves
-- the question, so an upload can raise it later; it only ever grows.
ALTER TABLE attempt ADD COLUMN review_ms INTEGER;

-- +goose Down
ALTER TABLE attempt DROP COLUMN review_ms;
