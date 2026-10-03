// Package db opens the SQLite database with a split read/write connection
// pool and applies embedded goose migrations.
package db

import (
	"context"
	"database/sql"
	"embed"
	"fmt"
	"net/url"
	"os"
	"path/filepath"

	"github.com/pressly/goose/v3"
	_ "modernc.org/sqlite"
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

// DB holds two pools over the same file. SQLite allows a single writer at a
// time, so the write pool is capped at one connection: writers queue in Go
// instead of failing with SQLITE_BUSY. Reads use WAL and run concurrently.
type DB struct {
	Write *sql.DB
	Read  *sql.DB
}

// Open opens (creating if needed) the database at path and runs migrations.
func Open(path string) (*DB, error) {
	if path != ":memory:" {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return nil, fmt.Errorf("create data dir: %w", err)
		}
	}
	write, err := openPool(path, true)
	if err != nil {
		return nil, err
	}
	write.SetMaxOpenConns(1)
	if err := migrate(write); err != nil {
		write.Close()
		return nil, err
	}
	read, err := openPool(path, false)
	if err != nil {
		write.Close()
		return nil, err
	}
	read.SetMaxOpenConns(8)
	return &DB{Write: write, Read: read}, nil
}

func (d *DB) Close() error {
	rerr := d.Read.Close()
	werr := d.Write.Close()
	if werr != nil {
		return werr
	}
	return rerr
}

// WithTx runs fn inside a short write transaction. Never call the network or an
// LLM from inside fn: the single write connection stays held for its duration.
func (d *DB) WithTx(ctx context.Context, fn func(tx *sql.Tx) error) error {
	tx, err := d.Write.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	if err := fn(tx); err != nil {
		_ = tx.Rollback()
		return err
	}
	return tx.Commit()
}

func openPool(path string, writer bool) (*sql.DB, error) {
	q := url.Values{}
	q.Add("_pragma", "busy_timeout(5000)")
	q.Add("_pragma", "journal_mode(WAL)")
	q.Add("_pragma", "synchronous(NORMAL)")
	q.Add("_pragma", "foreign_keys(1)")
	if writer {
		// BEGIN IMMEDIATE takes the write lock up front, avoiding deadlock-style
		// upgrade failures when a read transaction later tries to write.
		q.Set("_txlock", "immediate")
	}
	dsn := "file:" + path + "?" + q.Encode()
	if path == ":memory:" {
		return nil, fmt.Errorf("in-memory databases are not supported with split pools; use a temp file")
	}
	conn, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	if err := conn.Ping(); err != nil {
		conn.Close()
		return nil, fmt.Errorf("ping sqlite: %w", err)
	}
	return conn, nil
}

func migrate(conn *sql.DB) error {
	provider, err := goose.NewProvider(goose.DialectSQLite3, conn, subFS())
	if err != nil {
		return fmt.Errorf("goose provider: %w", err)
	}
	if _, err := provider.Up(context.Background()); err != nil {
		return fmt.Errorf("migrate: %w", err)
	}
	return nil
}
