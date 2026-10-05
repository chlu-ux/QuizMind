-- +goose Up

-- Questions now carry the document (module) they were generated from, so the app can practise
-- one chapter at a time. Devices only learn about it by pulling the question again, so every
-- synced question is moved past the current counter. Adding the counter to the old value keeps
-- the order (the old values are unique); the gaps are harmless because devices only compare.
UPDATE question SET sync_seq = sync_seq + (SELECT value FROM sync_counter WHERE id = 1)
WHERE sync_seq IS NOT NULL;
UPDATE sync_counter SET value = MAX(value, COALESCE((SELECT MAX(sync_seq) FROM question), 0)) WHERE id = 1;

-- +goose Down
SELECT 1;
