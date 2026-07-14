package identity

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"testing"
	"time"

	"github.com/eli/obelisk/server/internal/model"
	"github.com/google/uuid"
)

type memoryRepository struct {
	account     model.Account
	session     model.Session
	refreshHash []byte
}

func (repository *memoryRepository) AccountByEmail(_ context.Context, email string) (model.Account, error) {
	if repository.account.Email != email {
		return model.Account{}, ErrInvalidPassword
	}
	return repository.account, nil
}

func (repository *memoryRepository) CreateSession(_ context.Context, session model.Session, hash []byte) error {
	repository.session = session
	repository.refreshHash = hash
	return nil
}

func (repository *memoryRepository) RotateSession(
	_ context.Context,
	sessionID uuid.UUID,
	currentHash []byte,
	nextHash []byte,
	expiresAt time.Time,
	_ time.Time,
) (model.Session, error) {
	if repository.session.ID != sessionID || string(repository.refreshHash) != string(currentHash) {
		return model.Session{}, ErrInvalidRefreshToken
	}
	repository.refreshHash = nextHash
	repository.session.ExpiresAt = expiresAt
	return repository.session, nil
}

func TestProvisionLoginAndRefresh(t *testing.T) {
	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	issuer := &TokenIssuer{
		issuer:     "https://api.obelisk.test",
		keyID:      "test-key",
		privateKey: privateKey,
		publicKey:  &privateKey.PublicKey,
	}
	repository := &memoryRepository{}
	service := NewService(repository, issuer, 15*time.Minute, 30*24*time.Hour)
	now := time.Date(2026, 7, 14, 10, 0, 0, 0, time.UTC)
	deviceID := uuid.New()

	account, err := NewAccount(" ELI@Example.com ", "correct horse battery staple")
	if err != nil {
		t.Fatal(err)
	}
	repository.account = account
	if account.Email != "eli@example.com" || VerifyPassword(account.PasswordHash, "correct horse battery staple") != nil {
		t.Fatal("account provisioning did not normalize and hash credentials")
	}

	loggedIn, err := service.Login(context.Background(), "eli@example.com", "correct horse battery staple", deviceID, now)
	if err != nil {
		t.Fatal(err)
	}
	refreshed, err := service.Refresh(context.Background(), loggedIn.RefreshToken, now.Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if refreshed.RefreshToken == loggedIn.RefreshToken {
		t.Fatal("refresh token was not rotated")
	}
	if _, err := service.Refresh(context.Background(), loggedIn.RefreshToken, now.Add(2*time.Minute)); err == nil {
		t.Fatal("rotated refresh token was accepted again")
	}
}
