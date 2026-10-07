-- +goose Up

-- Questions now carry the id of the chunk (lesson section) they were generated from, so the app
-- can open the section a question belongs to and practise one section at a time. Devices only
-- learn about it by pulling the question again, so every synced question is moved past the
-- current counter, the same way migration 00009 did for the document.
UPDATE question SET sync_seq = sync_seq + (SELECT value FROM sync_counter WHERE id = 1)
WHERE sync_seq IS NOT NULL;
UPDATE sync_counter SET value = MAX(value, COALESCE((SELECT MAX(sync_seq) FROM question), 0)) WHERE id = 1;

-- +goose Down
SELECT 1;
