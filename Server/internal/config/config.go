package config

import (
	"errors"
	"os"
	"strings"
	"time"
)

type Config struct {
	ListenAddress     string
	DatabaseURL       string
	Issuer            string
	KeyID             string
	PrivateKeyPath    string
	AccessTokenTTL    time.Duration
	PowerSyncTokenTTL time.Duration
	RefreshTokenTTL   time.Duration
	AllowedOrigin     string
}

func Load() (Config, error) {
	config := Config{
		ListenAddress:     envOr("OBELISK_LISTEN_ADDRESS", ":8081"),
		DatabaseURL:       strings.TrimSpace(os.Getenv("OBELISK_DATABASE_URL")),
		Issuer:            strings.TrimSpace(os.Getenv("OBELISK_TOKEN_ISSUER")),
		KeyID:             strings.TrimSpace(os.Getenv("OBELISK_JWT_KEY_ID")),
		PrivateKeyPath:    strings.TrimSpace(os.Getenv("OBELISK_JWT_PRIVATE_KEY_PATH")),
		AccessTokenTTL:    15 * time.Minute,
		PowerSyncTokenTTL: time.Hour,
		RefreshTokenTTL:   30 * 24 * time.Hour,
		AllowedOrigin:     strings.TrimSpace(os.Getenv("OBELISK_ALLOWED_ORIGIN")),
	}

	var missing []string
	if config.DatabaseURL == "" {
		missing = append(missing, "OBELISK_DATABASE_URL")
	}
	if config.Issuer == "" {
		missing = append(missing, "OBELISK_TOKEN_ISSUER")
	}
	if config.KeyID == "" {
		missing = append(missing, "OBELISK_JWT_KEY_ID")
	}
	if config.PrivateKeyPath == "" {
		missing = append(missing, "OBELISK_JWT_PRIVATE_KEY_PATH")
	}
	if len(missing) > 0 {
		return Config{}, errors.New("missing required environment: " + strings.Join(missing, ", "))
	}

	return config, nil
}

func envOr(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}
