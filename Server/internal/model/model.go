package model

import (
	"time"

	"github.com/google/uuid"
)

type Account struct {
	ID           uuid.UUID
	Email        string
	PasswordHash string
}

type Session struct {
	ID        uuid.UUID
	AccountID uuid.UUID
	DeviceID  uuid.UUID
	ExpiresAt time.Time
}

type AuthTokens struct {
	AccountID    uuid.UUID `json:"accountId"`
	DeviceID     uuid.UUID `json:"deviceId"`
	AccessToken  string    `json:"accessToken"`
	RefreshToken string    `json:"refreshToken"`
	ExpiresAt    time.Time `json:"expiresAt"`
}
