package db_test

import (
	"context"
	"database/sql"
	"fmt"
	"path/filepath"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/chlu-ux/quizmind/server/internal/db"
)

func open(t *testing.T) *db.DB {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "nested", "app.db"))
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	return d
}

func TestOpen_PragmasAndMigrations(t *testing.T) {
	d := open(t)
	for name, pool := range map[string]*sql.DB{"write": d.Write, "read": d.Read} {
		var mode string
		require.NoError(t, pool.QueryRow("PRAGMA journal_mode").Scan(&mode))
		assert.Equal(t, "wal", mode, name)
		var fk int
		require.NoError(t, pool.QueryRow("PRAGMA foreign_keys").Scan(&fk))
		assert.Equal(t, 1, fk, name)
	}
	var n int
	require.NoError(t, d.Read.QueryRow("SELECT value FROM sync_counter WHERE id = 1").Scan(&n))
	assert.Equal(t, 0, n, "migration seeded the sync counter")
	assert.Equal(t, 1, d.Write.Stats().MaxOpenConnections, "single writer")
}

func TestOpen_ReopenIsIdempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "app.db")
	d, err := db.Open(path)
	require.NoError(t, err)
	_, err = d.Write.Exec(`INSERT INTO bank (id, title, created_at) VALUES ('b1', 't', 1)`)
	require.NoError(t, err)
	require.NoError(t, d.Close())

	d, err = db.Open(path)
	require.NoError(t, err, "re-running migrations on an existing database is a no-op")
	defer d.Close()
	var title string
	require.NoError(t, d.Read.QueryRow(`SELECT title FROM bank WHERE id = 'b1'`).Scan(&title))
	assert.Equal(t, "t", title, "data survives reopen")
}

func TestConcurrentWritersAndReadersNeverSeeBusy(t *testing.T) {
	d := open(t)
	ctx := context.Background()
	const writers, perWriter = 8, 25

	var wg sync.WaitGroup
	errs := make(chan error, writers*perWriter+64)
	for w := 0; w < writers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for i := 0; i < perWriter; i++ {
				err := d.WithTx(ctx, func(tx *sql.Tx) error {
					_, err := tx.ExecContext(ctx, `INSERT INTO bank (id, title, created_at) VALUES (?, 't', 1)`, fmt.Sprintf("w%d-%d", w, i))
					return err
				})
				if err != nil {
					errs <- err
				}
			}
		}(w)
	}
	for r := 0; r < 4; r++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 50; i++ {
				var n int
				if err := d.Read.QueryRowContext(ctx, `SELECT COUNT(*) FROM bank`).Scan(&n); err != nil {
					errs <- err
				}
			}
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Errorf("unexpected error: %v", err)
	}
	var n int
	require.NoError(t, d.Read.QueryRow(`SELECT COUNT(*) FROM bank`).Scan(&n))
	assert.Equal(t, writers*perWriter, n)
}

func TestWithTx_RollsBackOnError(t *testing.T) {
	d := open(t)
	ctx := context.Background()
	err := d.WithTx(ctx, func(tx *sql.Tx) error {
		_, _ = tx.ExecContext(ctx, `INSERT INTO bank (id, title, created_at) VALUES ('x', 't', 1)`)
		return fmt.Errorf("abort")
	})
	require.Error(t, err)
	var n int
	require.NoError(t, d.Read.QueryRow(`SELECT COUNT(*) FROM bank`).Scan(&n))
	assert.Equal(t, 0, n)
}

func TestSchemaConstraints(t *testing.T) {
	d := open(t)
	_, err := d.Write.Exec(`INSERT INTO document (id, bank_id, title, source_path, content, content_hash, status, created_at, updated_at)
		VALUES ('d','missing','t','a.md','c','h','imported',1,1)`)
	assert.Error(t, err, "foreign key enforced")
	_, err = d.Write.Exec(`INSERT INTO bank (id, title, created_at) VALUES ('b','t',1)`)
	require.NoError(t, err)
	_, err = d.Write.Exec(`INSERT INTO document (id, bank_id, title, source_path, content, content_hash, status, created_at, updated_at)
		VALUES ('d','b','t','a.md','c','h','bogus',1,1)`)
	assert.Error(t, err, "status CHECK enforced")
}

// Attempts that predate the sync_seq column are numbered in arrival order after
// the counter, so a second device can download them.
func TestMigration_BackfillsAttemptSyncSeq(t *testing.T) {
	path := filepath.Join(t.TempDir(), "app.db")
	d, err := db.Open(path)
	require.NoError(t, err)
	// Roll the schema back to what 00003 left, then add attempts the old way.
	for _, stmt := range []string{
		`PRAGMA foreign_keys = OFF`,
		`DROP TABLE agent_attachment`,
		`DROP TABLE agent_message`,
		`DROP TABLE agent_conversation`,
		`DROP TABLE agent_draft`,
		`DROP INDEX idx_flag_question`,
		`DROP TABLE question_flag`,
		`DROP TABLE media`,
		`DROP TABLE ai_note`,
		`DROP TABLE app_setting`,
		`DROP TABLE exam`,
		`DROP TABLE llm_model`,
		`DROP INDEX idx_llm_call_source`,
		`ALTER TABLE llm_call_log DROP COLUMN estimated`,
		`ALTER TABLE llm_call_log DROP COLUMN ref_id`,
		`ALTER TABLE llm_call_log DROP COLUMN device_id`,
		`ALTER TABLE llm_call_log DROP COLUMN source`,
		`DROP TABLE llm_provider`,
		`DROP INDEX idx_attempt_sync`,
		`ALTER TABLE attempt DROP COLUMN sync_seq`,
		`ALTER TABLE attempt DROP COLUMN review_ms`,
		`DELETE FROM goose_db_version WHERE version_id >= 4`,
		`UPDATE sync_counter SET value = 10 WHERE id = 1`,
		`INSERT INTO attempt (id, question_id, device_id, answer, is_correct, answered_at, received_at) VALUES
		   ('B', 'q', 'd', '[0]', 1, 1, 200), ('A', 'q', 'd', '[0]', 1, 1, 100), ('C', 'q', 'd', '[0]', 0, 1, 200)`,
	} {
		_, err := d.Write.Exec(stmt)
		require.NoError(t, err, stmt)
	}
	require.NoError(t, d.Close())

	d, err = db.Open(path)
	require.NoError(t, err)
	defer d.Close()
	got := map[string]int{}
	rows, err := d.Read.Query(`SELECT id, sync_seq FROM attempt`)
	require.NoError(t, err)
	for rows.Next() {
		var id string
		var seq int
		require.NoError(t, rows.Scan(&id, &seq))
		got[id] = seq
	}
	require.NoError(t, rows.Err())
	assert.Equal(t, map[string]int{"A": 11, "B": 12, "C": 13}, got, "ordered by received_at, then id")
	var counter int
	require.NoError(t, d.Read.QueryRow(`SELECT value FROM sync_counter WHERE id = 1`).Scan(&counter))
	assert.Equal(t, 13, counter, "new rows continue after the backfill")
}

// Questions gain a document (module) in the sync payload (00009) and later their chunk (00011), which
// devices only see by pulling them again: each migration moves every synced question's sync_seq past
// the counter, keeping its old order. Both run here, so the numbers are shifted twice.
func TestMigration_RenumbersQuestionsForModuleSync(t *testing.T) {
	path := filepath.Join(t.TempDir(), "app.db")
	d, err := db.Open(path)
	require.NoError(t, err)
	for _, stmt := range []string{
		`DROP TABLE agent_attachment`,
		`DROP TABLE agent_message`,
		`DROP TABLE agent_conversation`,
		`DROP TABLE agent_draft`,
		`DROP TABLE media`,
		`DROP TABLE llm_model`,
		`DROP INDEX idx_llm_call_source`,
		`ALTER TABLE llm_call_log DROP COLUMN estimated`,
		`ALTER TABLE llm_call_log DROP COLUMN ref_id`,
		`ALTER TABLE llm_call_log DROP COLUMN device_id`,
		`ALTER TABLE llm_call_log DROP COLUMN source`,
		`DROP TABLE llm_provider`,
		`DELETE FROM goose_db_version WHERE version_id >= 9`,
		`UPDATE sync_counter SET value = 100 WHERE id = 1`,
		`INSERT INTO bank (id, title, created_at) VALUES ('b', 't', 1)`,
		`INSERT INTO question (id, bank_id, type, stem, answer, source_quote, status, content_hash, sync_seq, created_at, updated_at) VALUES
		   ('q2', 'b', 'single', 's', '[0]', 'x', 'published', 'h2', 7, 1, 1),
		   ('q1', 'b', 'single', 's', '[0]', 'x', 'published', 'h1', 3, 1, 1),
		   ('q3', 'b', 'single', 's', '[0]', 'x', 'rejected', 'h3', 9, 1, 1),
		   ('q4', 'b', 'single', 's', '[0]', 'x', 'draft', 'h4', NULL, 1, 1)`,
	} {
		_, err := d.Write.Exec(stmt)
		require.NoError(t, err, stmt)
	}
	require.NoError(t, d.Close())

	d, err = db.Open(path)
	require.NoError(t, err)
	defer d.Close()
	got := map[string]sql.NullInt64{}
	rows, err := d.Read.Query(`SELECT id, sync_seq FROM question`)
	require.NoError(t, err)
	for rows.Next() {
		var id string
		var seq sql.NullInt64
		require.NoError(t, rows.Scan(&id, &seq))
		got[id] = seq
	}
	require.NoError(t, rows.Err())
	// 00009 adds the counter (100): 103, 107, 109 and the counter becomes 109; 00011 adds 109 again.
	assert.Equal(t, int64(212), got["q1"].Int64)
	assert.Equal(t, int64(216), got["q2"].Int64, "the old order is kept")
	assert.Equal(t, int64(218), got["q3"].Int64, "withdrawn questions are re-announced too")
	assert.False(t, got["q4"].Valid, "a question that was never synced stays unsynced")
	var counter int
	require.NoError(t, d.Read.QueryRow(`SELECT value FROM sync_counter WHERE id = 1`).Scan(&counter))
	assert.Equal(t, 218, counter, "new rows continue after the renumbered ones")
}
