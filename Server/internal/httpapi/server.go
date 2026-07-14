package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/eli/obelisk/server/internal/identity"
	"github.com/eli/obelisk/server/internal/mutation"
	"github.com/google/uuid"
)

type Server struct {
	identity          *identity.Service
	mutations         *mutation.Service
	tokens            *identity.TokenIssuer
	powerSyncTokenTTL time.Duration
	allowedOrigin     string
	databaseHealth    func(context.Context) error
	now               func() time.Time
}

type credentialsRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
	DeviceID string `json:"deviceId"`
}

type refreshRequest struct {
	RefreshToken string `json:"refreshToken"`
}

type powerSyncTokenResponse struct {
	Token     string    `json:"token"`
	ExpiresAt time.Time `json:"expiresAt"`
}

type errorResponse struct {
	Error string `json:"error"`
}

func NewServer(
	identityService *identity.Service,
	mutationService *mutation.Service,
	tokens *identity.TokenIssuer,
	powerSyncTokenTTL time.Duration,
	allowedOrigin string,
	databaseHealth func(context.Context) error,
) *Server {
	return &Server{
		identity:          identityService,
		mutations:         mutationService,
		tokens:            tokens,
		powerSyncTokenTTL: powerSyncTokenTTL,
		allowedOrigin:     allowedOrigin,
		databaseHealth:    databaseHealth,
		now:               func() time.Time { return time.Now().UTC() },
	}
}

func (server *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", server.health)
	mux.HandleFunc("GET /.well-known/jwks.json", server.jwks)
	mux.HandleFunc("POST /v1/auth/login", server.login)
	mux.HandleFunc("POST /v1/auth/refresh", server.refresh)
	mux.Handle("GET /v1/auth/powersync-token", server.requireAccessToken(http.HandlerFunc(server.powerSyncToken)))
	mux.Handle("POST /v1/sync/mutations", server.requireAccessToken(http.HandlerFunc(server.applyMutations)))
	return server.cors(mux)
}

func (server *Server) health(response http.ResponseWriter, request *http.Request) {
	ctx, cancel := context.WithTimeout(request.Context(), 2*time.Second)
	defer cancel()
	if err := server.databaseHealth(ctx); err != nil {
		writeError(response, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	writeJSON(response, http.StatusOK, map[string]string{"status": "ok"})
}

func (server *Server) jwks(response http.ResponseWriter, _ *http.Request) {
	writeJSON(response, http.StatusOK, server.tokens.JWKS())
}

func (server *Server) login(response http.ResponseWriter, request *http.Request) {
	credentials, deviceID, ok := decodeCredentials(response, request)
	if !ok {
		return
	}
	tokens, err := server.identity.Login(
		request.Context(), credentials.Email, credentials.Password, deviceID, server.now(),
	)
	if err != nil {
		writeIdentityError(response, err)
		return
	}
	writeJSON(response, http.StatusOK, tokens)
}

func (server *Server) refresh(response http.ResponseWriter, request *http.Request) {
	var body refreshRequest
	if err := decodeJSON(request, &body); err != nil || body.RefreshToken == "" {
		writeError(response, http.StatusBadRequest, "invalid request")
		return
	}
	tokens, err := server.identity.Refresh(request.Context(), body.RefreshToken, server.now())
	if err != nil {
		writeIdentityError(response, err)
		return
	}
	writeJSON(response, http.StatusOK, tokens)
}

func (server *Server) powerSyncToken(response http.ResponseWriter, request *http.Request) {
	claims := request.Context().Value(claimsContextKey{}).(*identity.Claims)
	accountID, _ := uuid.Parse(claims.Subject)
	deviceID, _ := uuid.Parse(claims.DeviceID)
	token, expiresAt, err := server.tokens.Issue(
		accountID,
		deviceID,
		identity.PowerSyncAudience,
		server.powerSyncTokenTTL,
		server.now(),
	)
	if err != nil {
		writeError(response, http.StatusInternalServerError, "could not issue sync token")
		return
	}
	writeJSON(response, http.StatusOK, powerSyncTokenResponse{Token: token, ExpiresAt: expiresAt})
}

func (server *Server) applyMutations(response http.ResponseWriter, request *http.Request) {
	var body mutation.Request
	if err := decodeJSON(request, &body); err != nil {
		writeError(response, http.StatusBadRequest, "invalid mutation batch")
		return
	}
	claims := request.Context().Value(claimsContextKey{}).(*identity.Claims)
	ownerID, _ := uuid.Parse(claims.Subject)
	deviceID, _ := uuid.Parse(claims.DeviceID)
	if err := server.mutations.Apply(request.Context(), ownerID, deviceID, body); err != nil {
		slog.Error("mutation batch failed", "owner_id", ownerID, "device_id", deviceID, "error", err)
		writeError(response, http.StatusBadRequest, "invalid mutation batch")
		return
	}
	response.WriteHeader(http.StatusNoContent)
}

type claimsContextKey struct{}

func (server *Server) requireAccessToken(next http.Handler) http.Handler {
	return http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		authorization := strings.Fields(request.Header.Get("Authorization"))
		if len(authorization) != 2 || !strings.EqualFold(authorization[0], "Bearer") {
			writeError(response, http.StatusUnauthorized, "authentication required")
			return
		}
		claims, err := server.tokens.Verify(authorization[1], identity.APIAudience, server.now())
		if err != nil {
			writeError(response, http.StatusUnauthorized, "authentication required")
			return
		}
		if _, err := uuid.Parse(claims.Subject); err != nil {
			writeError(response, http.StatusUnauthorized, "authentication required")
			return
		}
		if _, err := uuid.Parse(claims.DeviceID); err != nil {
			writeError(response, http.StatusUnauthorized, "authentication required")
			return
		}
		ctx := context.WithValue(request.Context(), claimsContextKey{}, claims)
		next.ServeHTTP(response, request.WithContext(ctx))
	})
}

func (server *Server) cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if server.allowedOrigin != "" && request.Header.Get("Origin") == server.allowedOrigin {
			response.Header().Set("Access-Control-Allow-Origin", server.allowedOrigin)
			response.Header().Set("Vary", "Origin")
		}
		next.ServeHTTP(response, request)
	})
}

func decodeCredentials(response http.ResponseWriter, request *http.Request) (credentialsRequest, uuid.UUID, bool) {
	var body credentialsRequest
	if err := decodeJSON(request, &body); err != nil {
		writeError(response, http.StatusBadRequest, "invalid request")
		return credentialsRequest{}, uuid.Nil, false
	}
	deviceID, err := uuid.Parse(body.DeviceID)
	if err != nil {
		writeError(response, http.StatusBadRequest, "invalid deviceId")
		return credentialsRequest{}, uuid.Nil, false
	}
	return body, deviceID, true
}

func decodeJSON(request *http.Request, destination any) error {
	decoder := json.NewDecoder(io.LimitReader(request.Body, 2*1024*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	if decoder.Decode(&struct{}{}) == nil {
		return errors.New("multiple JSON values")
	}
	return nil
}

func writeIdentityError(response http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, identity.ErrInvalidEmail):
		writeError(response, http.StatusBadRequest, err.Error())
	case errors.Is(err, identity.ErrPasswordPolicy):
		writeError(response, http.StatusBadRequest, err.Error())
	case errors.Is(err, identity.ErrInvalidPassword), errors.Is(err, identity.ErrInvalidRefreshToken):
		writeError(response, http.StatusUnauthorized, err.Error())
	default:
		writeError(response, http.StatusInternalServerError, "internal server error")
	}
}

func writeError(response http.ResponseWriter, status int, message string) {
	writeJSON(response, status, errorResponse{Error: message})
}

func writeJSON(response http.ResponseWriter, status int, value any) {
	response.Header().Set("Content-Type", "application/json")
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(value)
}
