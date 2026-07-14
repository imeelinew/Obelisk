package postgres

import (
	"context"
	"crypto/subtle"
	"errors"
	"fmt"
	"time"

	"github.com/eli/obelisk/server/internal/identity"
	"github.com/eli/obelisk/server/internal/model"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Store struct {
	pool *pgxpool.Pool
}

func NewStore(pool *pgxpool.Pool) *Store {
	return &Store{pool: pool}
}

func (store *Store) CreateAccount(ctx context.Context, account model.Account) error {
	if _, err := store.pool.Exec(ctx,
		"INSERT INTO accounts(id, email, password_hash) VALUES ($1, $2, $3)",
		account.ID, account.Email, account.PasswordHash,
	); err != nil {
		var postgresError *pgconn.PgError
		if errors.As(err, &postgresError) && postgresError.Code == "23505" {
			return identity.ErrEmailTaken
		}
		return fmt.Errorf("insert account: %w", err)
	}
	return nil
}

func (store *Store) AccountByEmail(ctx context.Context, email string) (model.Account, error) {
	var account model.Account
	err := store.pool.QueryRow(ctx,
		"SELECT id, email, password_hash FROM accounts WHERE email = $1",
		email,
	).Scan(&account.ID, &account.Email, &account.PasswordHash)
	if errors.Is(err, pgx.ErrNoRows) {
		return model.Account{}, identity.ErrInvalidPassword
	}
	if err != nil {
		return model.Account{}, fmt.Errorf("select account: %w", err)
	}
	return account, nil
}

func (store *Store) CreateSession(
	ctx context.Context,
	session model.Session,
	refreshTokenHash []byte,
) error {
	tx, err := store.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin session: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := insertSession(ctx, tx, session, refreshTokenHash); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit session: %w", err)
	}
	return nil
}

func (store *Store) RotateSession(
	ctx context.Context,
	sessionID uuid.UUID,
	currentHash []byte,
	nextHash []byte,
	expiresAt time.Time,
	now time.Time,
) (model.Session, error) {
	tx, err := store.pool.Begin(ctx)
	if err != nil {
		return model.Session{}, fmt.Errorf("begin token rotation: %w", err)
	}
	defer tx.Rollback(ctx)

	var session model.Session
	var storedHash []byte
	err = tx.QueryRow(ctx, `
		SELECT id, owner_id, device_id, expires_at, refresh_token_hash
		FROM sessions
		WHERE id = $1 AND revoked_at IS NULL
		FOR UPDATE
	`, sessionID).Scan(
		&session.ID,
		&session.AccountID,
		&session.DeviceID,
		&session.ExpiresAt,
		&storedHash,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return model.Session{}, identity.ErrInvalidRefreshToken
	}
	if err != nil {
		return model.Session{}, fmt.Errorf("select session: %w", err)
	}
	if !session.ExpiresAt.After(now) || subtle.ConstantTimeCompare(storedHash, currentHash) != 1 {
		return model.Session{}, identity.ErrInvalidRefreshToken
	}

	if _, err := tx.Exec(ctx, `
		UPDATE sessions
		SET refresh_token_hash = $2, expires_at = $3, rotated_at = $4
		WHERE id = $1
	`, sessionID, nextHash, expiresAt, now); err != nil {
		return model.Session{}, fmt.Errorf("rotate session: %w", err)
	}
	if _, err := tx.Exec(ctx,
		"UPDATE devices SET last_seen_at = $2 WHERE id = $1",
		session.DeviceID, now,
	); err != nil {
		return model.Session{}, fmt.Errorf("update device: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return model.Session{}, fmt.Errorf("commit token rotation: %w", err)
	}
	session.ExpiresAt = expiresAt
	return session, nil
}

func insertSession(
	ctx context.Context,
	tx pgx.Tx,
	session model.Session,
	refreshTokenHash []byte,
) error {
	if _, err := tx.Exec(ctx, `
		INSERT INTO devices(id, owner_id)
		VALUES ($1, $2)
		ON CONFLICT (id) DO UPDATE SET last_seen_at = now()
	`, session.DeviceID, session.AccountID); err != nil {
		return fmt.Errorf("upsert device: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO sessions(id, owner_id, device_id, refresh_token_hash, expires_at)
		VALUES ($1, $2, $3, $4, $5)
	`, session.ID, session.AccountID, session.DeviceID, refreshTokenHash, session.ExpiresAt); err != nil {
		return fmt.Errorf("insert session: %w", err)
	}
	return nil
}

func isUndefinedTable(err error) bool {
	var postgresError *pgconn.PgError
	return errors.As(err, &postgresError) && postgresError.Code == "42P01"
}
