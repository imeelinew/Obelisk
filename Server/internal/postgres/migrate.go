package postgres

import (
	"context"
	_ "embed"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed migrations/001_initial.sql
var initialSchema string

//go:embed migrations/002_browser_history.sql
var browserHistoryMigration string

//go:embed migrations/003_browser_history_settings.sql
var browserHistorySettingsMigration string

func ApplySchema(ctx context.Context, pool *pgxpool.Pool) error {
	var version int
	err := pool.QueryRow(ctx, "SELECT version FROM schema_version").Scan(&version)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return errors.New("schema_version is empty")
	case err == nil:
		switch version {
		case 1:
			if err := applyMigration(ctx, pool, browserHistoryMigration); err != nil {
				return err
			}
			fallthrough
		case 2:
			return applyMigration(ctx, pool, browserHistorySettingsMigration)
		case 3:
			return nil
		default:
			return fmt.Errorf("database schema version is %d; expected 1, 2, or 3", version)
		}
	case !isUndefinedTable(err):
		return fmt.Errorf("read schema version: %w", err)
	}

	tx, err := pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin schema transaction: %w", err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, initialSchema); err != nil {
		return fmt.Errorf("apply initial schema: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit initial schema: %w", err)
	}
	return nil
}

func applyMigration(ctx context.Context, pool *pgxpool.Pool, sql string) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin schema migration: %w", err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, sql); err != nil {
		return fmt.Errorf("apply schema migration: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit schema migration: %w", err)
	}
	return nil
}
