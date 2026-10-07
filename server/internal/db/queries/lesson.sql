-- name: ListLessons :many
-- Every readable section of every document (a chapter of a bank), in reading order: documents
-- in the order they were added, sections in document order. Superseded sections are left out.
SELECT c.id, c.seq, c.heading_path, c.text, c.content_hash,
       d.id AS document_id, d.bank_id, d.title AS document_title, d.created_at AS document_created_at
FROM chunk c JOIN document d ON d.id = c.document_id
WHERE c.status = 'active'
ORDER BY d.bank_id, d.created_at, d.id, c.seq;
