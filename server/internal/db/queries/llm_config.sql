-- name: ListLLMProviders :many
SELECT * FROM llm_provider ORDER BY created_at, id;

-- name: GetLLMProvider :one
SELECT * FROM llm_provider WHERE id = ?;

-- name: InsertLLMProvider :exec
INSERT INTO llm_provider (id, name, protocol, base_url, api_key, created_at, updated_at)
VALUES (?, ?, ?, ?, ?, ?, ?);

-- name: UpdateLLMProvider :execrows
UPDATE llm_provider SET name = ?, protocol = ?, base_url = ?, api_key = ?, updated_at = ? WHERE id = ?;

-- name: DeleteLLMProvider :exec
DELETE FROM llm_provider WHERE id = ?;

-- name: ListLLMModels :many
SELECT * FROM llm_model ORDER BY created_at, id;

-- name: GetLLMModel :one
SELECT * FROM llm_model WHERE id = ?;

-- name: ListLLMModelsByProvider :many
SELECT * FROM llm_model WHERE provider_id = ? ORDER BY created_at, id;

-- name: InsertLLMModel :exec
INSERT INTO llm_model (id, provider_id, name, model, max_tokens, temperature, effort, vision, created_at, updated_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);

-- name: UpdateLLMModel :execrows
UPDATE llm_model SET provider_id = ?, name = ?, model = ?, max_tokens = ?, temperature = ?, effort = ?, vision = ?, updated_at = ?
WHERE id = ?;

-- name: DeleteLLMModel :exec
DELETE FROM llm_model WHERE id = ?;
