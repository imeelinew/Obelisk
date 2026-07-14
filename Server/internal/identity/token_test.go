package identity

import (
	"crypto/rand"
	"crypto/rsa"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestJWTIsBoundToAudienceAndIdentity(t *testing.T) {
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
	now := time.Date(2026, 7, 14, 10, 0, 0, 0, time.UTC)
	accountID := uuid.New()
	deviceID := uuid.New()
	token, _, err := issuer.Issue(accountID, deviceID, PowerSyncAudience, time.Hour, now)
	if err != nil {
		t.Fatal(err)
	}

	claims, err := issuer.Verify(token, PowerSyncAudience, now.Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if claims.Subject != accountID.String() || claims.DeviceID != deviceID.String() {
		t.Fatalf("unexpected claims: %#v", claims)
	}
	if _, err := issuer.Verify(token, APIAudience, now.Add(time.Minute)); err == nil {
		t.Fatal("PowerSync token accepted by the API audience")
	}
	if _, err := issuer.Verify(token, PowerSyncAudience, now.Add(2*time.Hour)); err == nil {
		t.Fatal("expired token accepted")
	}
}

func TestRefreshTokenRoundTrip(t *testing.T) {
	sessionID := uuid.New()
	token, hash, err := NewRefreshToken(sessionID)
	if err != nil {
		t.Fatal(err)
	}
	parsedID, parsedHash, err := ParseRefreshToken(token)
	if err != nil {
		t.Fatal(err)
	}
	if parsedID != sessionID || string(parsedHash) != string(hash) {
		t.Fatal("refresh token did not round-trip")
	}
}
