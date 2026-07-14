package config

import (
	"strings"
	"testing"
)

func TestLoadRequiresEveryDeploymentSecretAndIdentity(t *testing.T) {
	t.Setenv("OBELISK_DATABASE_URL", "")
	t.Setenv("OBELISK_TOKEN_ISSUER", "")
	t.Setenv("OBELISK_JWT_KEY_ID", "")
	t.Setenv("OBELISK_JWT_PRIVATE_KEY_PATH", "")

	_, err := Load()
	if err == nil {
		t.Fatal("accepted an incomplete production configuration")
	}
	for _, name := range []string{
		"OBELISK_DATABASE_URL",
		"OBELISK_TOKEN_ISSUER",
		"OBELISK_JWT_KEY_ID",
		"OBELISK_JWT_PRIVATE_KEY_PATH",
	} {
		if !strings.Contains(err.Error(), name) {
			t.Fatalf("missing variable %s from error: %v", name, err)
		}
	}
}

func TestLoadUsesExplicitDeploymentConfiguration(t *testing.T) {
	t.Setenv("OBELISK_DATABASE_URL", "postgresql://example")
	t.Setenv("OBELISK_TOKEN_ISSUER", "https://api.example.test")
	t.Setenv("OBELISK_JWT_KEY_ID", "test-key")
	t.Setenv("OBELISK_JWT_PRIVATE_KEY_PATH", "/run/secrets/key.pem")

	configuration, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if configuration.Issuer != "https://api.example.test" {
		t.Fatalf("unexpected issuer: %s", configuration.Issuer)
	}
}
