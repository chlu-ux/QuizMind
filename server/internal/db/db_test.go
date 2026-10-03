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
