package identity

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/eli/obelisk/server/internal/model"
	"github.com/google/uuid"
)

var (
	ErrEmailTaken          = errors.New("an account already exists for this email")
	ErrInvalidEmail        = errors.New("invalid email address")
	ErrInvalidRefreshToken = errors.New("invalid refresh token")
)

type Repository interface {
	AccountByEmail(context.Context, string) (model.Account, error)
	CreateSession(context.Context, model.Session, []byte) error
	RotateSession(context.Context, uuid.UUID, []byte, []byte, time.Time, time.Time) (model.Session, error)
}

type Service struct {
	repository      Repository
	tokens          *TokenIssuer
	accessTokenTTL  time.Duration
	refreshTokenTTL time.Duration
}

func NewService(repository Repository, tokens *TokenIssuer, accessTokenTTL, refreshTokenTTL time.Duration) *Service {
	return &Service{
		repository:      repository,
		tokens:          tokens,
		accessTokenTTL:  accessTokenTTL,
		refreshTokenTTL: refreshTokenTTL,
	}
}

func NewAccount(email string, password string) (model.Account, error) {
	email, err := normalizeEmail(email)
	if err != nil {
		return model.Account{}, err
	}
	passwordHash, err := HashPassword(password)
	if err != nil {
		return model.Account{}, err
	}
	return model.Account{ID: uuid.New(), Email: email, PasswordHash: passwordHash}, nil
}

func (service *Service) Login(
	ctx context.Context,
	email string,
	password string,
	deviceID uuid.UUID,
	now time.Time,
) (model.AuthTokens, error) {
	email, err := normalizeEmail(email)
	if err != nil {
		return model.AuthTokens{}, ErrInvalidPassword
	}
	account, err := service.repository.AccountByEmail(ctx, email)
	if err != nil {
		return model.AuthTokens{}, err
	}
	if err := VerifyPassword(account.PasswordHash, password); err != nil {
		return model.AuthTokens{}, err
	}

	session, refreshToken, refreshHash, err := service.newSession(account.ID, deviceID, now)
	if err != nil {
		return model.AuthTokens{}, err
	}
	if err := service.repository.CreateSession(ctx, session, refreshHash); err != nil {
		return model.AuthTokens{}, err
	}
	return service.issueAuthTokens(account.ID, deviceID, refreshToken, now)
}

func (service *Service) Refresh(
	ctx context.Context,
	currentToken string,
	now time.Time,
) (model.AuthTokens, error) {
	sessionID, currentHash, err := ParseRefreshToken(currentToken)
	if err != nil {
		return model.AuthTokens{}, ErrInvalidRefreshToken
	}
	nextToken, nextHash, err := NewRefreshToken(sessionID)
	if err != nil {
		return model.AuthTokens{}, err
	}
	expiresAt := now.Add(service.refreshTokenTTL)
	session, err := service.repository.RotateSession(ctx, sessionID, currentHash, nextHash, expiresAt, now)
	if err != nil {
		return model.AuthTokens{}, err
	}
	return service.issueAuthTokens(session.AccountID, session.DeviceID, nextToken, now)
}

func (service *Service) newSession(accountID, deviceID uuid.UUID, now time.Time) (model.Session, string, []byte, error) {
	session := model.Session{
		ID:        uuid.New(),
		AccountID: accountID,
		DeviceID:  deviceID,
		ExpiresAt: now.Add(service.refreshTokenTTL),
	}
	refreshToken, refreshHash, err := NewRefreshToken(session.ID)
	return session, refreshToken, refreshHash, err
}

func (service *Service) issueAuthTokens(accountID, deviceID uuid.UUID, refreshToken string, now time.Time) (model.AuthTokens, error) {
	accessToken, expiresAt, err := service.tokens.Issue(accountID, deviceID, APIAudience, service.accessTokenTTL, now)
	if err != nil {
		return model.AuthTokens{}, err
	}
	return model.AuthTokens{
		AccountID:    accountID,
		DeviceID:     deviceID,
		AccessToken:  accessToken,
		RefreshToken: refreshToken,
		ExpiresAt:    expiresAt,
	}, nil
}

func normalizeEmail(email string) (string, error) {
	email = strings.ToLower(strings.TrimSpace(email))
	parts := strings.Split(email, "@")
	if len(parts) != 2 || parts[0] == "" || !strings.Contains(parts[1], ".") || len(email) > 254 {
		return "", ErrInvalidEmail
	}
	return email, nil
}
