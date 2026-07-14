package identity

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"os"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

const (
	APIAudience       = "obelisk-api"
	PowerSyncAudience = "powersync"
)

type Claims struct {
	DeviceID string `json:"device_id"`
	jwt.RegisteredClaims
}

type TokenIssuer struct {
	issuer     string
	keyID      string
	privateKey *rsa.PrivateKey
	publicKey  *rsa.PublicKey
}

type JSONWebKeySet struct {
	Keys []JSONWebKey `json:"keys"`
}

type JSONWebKey struct {
	KeyType   string `json:"kty"`
	Use       string `json:"use"`
	Algorithm string `json:"alg"`
	KeyID     string `json:"kid"`
	Modulus   string `json:"n"`
	Exponent  string `json:"e"`
}

func LoadTokenIssuer(issuer, keyID, privateKeyPath string) (*TokenIssuer, error) {
	data, err := os.ReadFile(privateKeyPath)
	if err != nil {
		return nil, fmt.Errorf("read JWT private key: %w", err)
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, errors.New("JWT private key is not PEM")
	}

	var key *rsa.PrivateKey
	if parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes); err == nil {
		var ok bool
		key, ok = parsed.(*rsa.PrivateKey)
		if !ok {
			return nil, errors.New("JWT private key is not RSA")
		}
	} else {
		key, err = x509.ParsePKCS1PrivateKey(block.Bytes)
		if err != nil {
			return nil, errors.New("JWT private key is not PKCS#8 or PKCS#1 RSA")
		}
	}
	if key.N.BitLen() < 2048 {
		return nil, errors.New("JWT RSA key must be at least 2048 bits")
	}

	return &TokenIssuer{
		issuer:     strings.TrimRight(issuer, "/"),
		keyID:      keyID,
		privateKey: key,
		publicKey:  &key.PublicKey,
	}, nil
}

func (issuer *TokenIssuer) Issue(accountID, deviceID uuid.UUID, audience string, ttl time.Duration, now time.Time) (string, time.Time, error) {
	expiresAt := now.Add(ttl)
	claims := Claims{
		DeviceID: deviceID.String(),
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    issuer.issuer,
			Subject:   accountID.String(),
			Audience:  jwt.ClaimStrings{audience},
			ExpiresAt: jwt.NewNumericDate(expiresAt),
			IssuedAt:  jwt.NewNumericDate(now),
			NotBefore: jwt.NewNumericDate(now),
			ID:        uuid.NewString(),
		},
	}
	token := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	token.Header["kid"] = issuer.keyID
	signed, err := token.SignedString(issuer.privateKey)
	if err != nil {
		return "", time.Time{}, fmt.Errorf("sign JWT: %w", err)
	}
	return signed, expiresAt, nil
}

func (issuer *TokenIssuer) Verify(tokenString, audience string, now time.Time) (*Claims, error) {
	claims := &Claims{}
	token, err := jwt.ParseWithClaims(
		tokenString,
		claims,
		func(token *jwt.Token) (any, error) {
			if token.Method != jwt.SigningMethodRS256 || token.Header["kid"] != issuer.keyID {
				return nil, errors.New("invalid JWT signing metadata")
			}
			return issuer.publicKey, nil
		},
		jwt.WithAudience(audience),
		jwt.WithIssuer(issuer.issuer),
		jwt.WithTimeFunc(func() time.Time { return now }),
		jwt.WithValidMethods([]string{jwt.SigningMethodRS256.Alg()}),
	)
	if err != nil || !token.Valid {
		return nil, errors.New("invalid access token")
	}
	return claims, nil
}

func (issuer *TokenIssuer) JWKS() JSONWebKeySet {
	return JSONWebKeySet{Keys: []JSONWebKey{{
		KeyType:   "RSA",
		Use:       "sig",
		Algorithm: "RS256",
		KeyID:     issuer.keyID,
		Modulus:   base64.RawURLEncoding.EncodeToString(issuer.publicKey.N.Bytes()),
		Exponent:  base64.RawURLEncoding.EncodeToString(big.NewInt(int64(issuer.publicKey.E)).Bytes()),
	}}}
}

func NewRefreshToken(sessionID uuid.UUID) (plain string, hash []byte, err error) {
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return "", nil, fmt.Errorf("generate refresh token: %w", err)
	}
	encoded := base64.RawURLEncoding.EncodeToString(secret)
	digest := sha256.Sum256([]byte(encoded))
	return sessionID.String() + "." + encoded, digest[:], nil
}

func ParseRefreshToken(token string) (uuid.UUID, []byte, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 2 {
		return uuid.Nil, nil, errors.New("invalid refresh token")
	}
	sessionID, err := uuid.Parse(parts[0])
	if err != nil {
		return uuid.Nil, nil, errors.New("invalid refresh token")
	}
	secret, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil || len(secret) != 32 {
		return uuid.Nil, nil, errors.New("invalid refresh token")
	}
	digest := sha256.Sum256([]byte(parts[1]))
	return sessionID, digest[:], nil
}
