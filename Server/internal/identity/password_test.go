package identity

import (
	"errors"
	"testing"
)

func TestPasswordHashRoundTrip(t *testing.T) {
	encoded, err := HashPassword("correct horse battery staple")
	if err != nil {
		t.Fatal(err)
	}
	if err := VerifyPassword(encoded, "correct horse battery staple"); err != nil {
		t.Fatalf("valid password rejected: %v", err)
	}
	if err := VerifyPassword(encoded, "wrong password"); !errors.Is(err, ErrInvalidPassword) {
		t.Fatalf("wrong password returned %v", err)
	}
}

func TestPasswordPolicy(t *testing.T) {
	if _, err := HashPassword("too short"); err == nil {
		t.Fatal("short password accepted")
	}
}
