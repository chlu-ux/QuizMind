-- +goose Up

-- Images used by questions (UML diagrams, flow charts, ...). Referenced from a stem, an
-- option or an explanation as `![alt](media:<id>)`. The id is a prefix of the content's
-- SHA-256, so the same picture is stored once and a URL never changes meaning.
CREATE TABLE media (
  id         TEXT PRIMARY KEY,
  mime       TEXT NOT NULL,
  size       INTEGER NOT NULL,
  width      INTEGER NOT NULL DEFAULT 0,
  height     INTEGER NOT NULL DEFAULT 0,
  data       BLOB NOT NULL,
  created_at INTEGER NOT NULL
);

-- +goose Down
DROP TABLE media;
