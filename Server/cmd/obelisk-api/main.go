package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/eli/obelisk/server/internal/config"
	"github.com/eli/obelisk/server/internal/httpapi"
	"github.com/eli/obelisk/server/internal/identity"
	"github.com/eli/obelisk/server/internal/mutation"
	"github.com/eli/obelisk/server/internal/postgres"
	"github.com/jackc/pgx/v5/pgxpool"
)

func main() {
	if len(os.Args) == 2 && os.Args[1] == "healthcheck" {
		if err := healthcheck(); err != nil {
			os.Exit(1)
		}
		return
	}
	if len(os.Args) == 3 && os.Args[1] == "create-account" {
		if err := createAccount(os.Args[2]); err != nil {
			slog.Error("could not create account", "error", err)
			os.Exit(1)
		}
		return
	}
	if err := run(); err != nil {
		slog.Error("Obelisk API stopped", "error", err)
		os.Exit(1)
	}
}

func createAccount(email string) error {
	settings, err := config.Load()
	if err != nil {
		return err
	}
	password, err := bufio.NewReader(os.Stdin).ReadString('\n')
	if err != nil {
		return fmt.Errorf("read password: %w", err)
	}
	account, err := identity.NewAccount(email, strings.TrimRight(password, "\r\n"))
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, settings.DatabaseURL)
	if err != nil {
		return err
	}
	defer pool.Close()
	if err := postgres.ApplySchema(ctx, pool); err != nil {
		return err
	}
	if err := postgres.NewStore(pool).CreateAccount(ctx, account); err != nil {
		return err
	}
	fmt.Printf("created account %s\n", account.Email)
	return nil
}

func healthcheck() error {
	client := http.Client{Timeout: 2 * time.Second}
	response, err := client.Get("http://127.0.0.1:8081/healthz")
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return errors.New("API is unhealthy")
	}
	return nil
}

func run() error {
	settings, err := config.Load()
	if err != nil {
		return err
	}
	tokenIssuer, err := identity.LoadTokenIssuer(
		settings.Issuer,
		settings.KeyID,
		settings.PrivateKeyPath,
	)
	if err != nil {
		return err
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	pool, err := pgxpool.New(ctx, settings.DatabaseURL)
	if err != nil {
		return err
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		return err
	}
	if err := postgres.ApplySchema(ctx, pool); err != nil {
		return err
	}

	repository := postgres.NewStore(pool)
	identityService := identity.NewService(
		repository,
		tokenIssuer,
		settings.AccessTokenTTL,
		settings.RefreshTokenTTL,
	)
	api := httpapi.NewServer(
		identityService,
		mutation.NewService(pool),
		tokenIssuer,
		settings.PowerSyncTokenTTL,
		settings.AllowedOrigin,
		pool.Ping,
	)
	httpServer := &http.Server{
		Addr:              settings.ListenAddress,
		Handler:           api.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	serverError := make(chan error, 1)
	go func() {
		slog.Info("Obelisk API listening", "address", settings.ListenAddress)
		serverError <- httpServer.ListenAndServe()
	}()

	select {
	case err := <-serverError:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	case <-ctx.Done():
		shutdownContext, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer shutdownCancel()
		return httpServer.Shutdown(shutdownContext)
	}
	return nil
}
