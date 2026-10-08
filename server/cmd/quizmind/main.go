// Command quizmind runs the QuizMind server: REST API, admin UI and the
// question-generation worker pool in a single process.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/chlu-ux/quizmind/server/internal/config"
	"github.com/chlu-ux/quizmind/server/internal/db"
	"github.com/chlu-ux/quizmind/server/internal/events"
	"github.com/chlu-ux/quizmind/server/internal/httpapi"
	"github.com/chlu-ux/quizmind/server/internal/jobs"
	"github.com/chlu-ux/quizmind/server/internal/llm"
	"github.com/chlu-ux/quizmind/server/internal/service"
	"github.com/chlu-ux/quizmind/server/web"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "quizmind:", err)
		os.Exit(1)
	}
}

func run() error {
	configPath := flag.String("config", "", "path to config YAML (defaults are used when empty)")
	flag.Parse()

	cfg, err := config.Load(*configPath)
	if err != nil {
		return err
	}
	log := slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return err
	}
	defer database.Close()

	hub := events.NewHub()
	queue := jobs.NewQueue(database)

	svc := service.New(database, cfg, llm.NewRegistry(), queue, hub, log)
	// Models are configured in the admin UI; the first start after upgrading imports the old settings.
	if err := svc.SeedLLMConfig(context.Background()); err != nil {
		return fmt.Errorf("import llm settings: %w", err)
	}
	if err := svc.ReloadLLM(context.Background()); err != nil {
		return fmt.Errorf("load llm configuration: %w", err)
	}
	runner := jobs.NewRunner(database, queue, cfg.Pipeline.WorkerConcurrency, log, hub)
	svc.RegisterHandlers(runner)

	if cfg.Auth.Token == "" {
		log.Warn("no auth token configured; accepting unauthenticated requests because the listener is loopback-only",
			"listen", cfg.Listen)
	}
	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           httpapi.New(svc, hub, cfg.Auth.Token, web.Dist(), log),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       2 * time.Minute,
	}

	// Streaming responses (SSE) would otherwise hold Shutdown until its timeout.
	srv.RegisterOnShutdown(hub.Close)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	workersDone := make(chan struct{})
	go func() { runner.Run(ctx); close(workersDone) }()

	serveErr := make(chan error, 1)
	go func() {
		log.Info("listening", "addr", cfg.Listen, "db", cfg.DBPath())
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serveErr <- err
		}
	}()

	select {
	case err := <-serveErr:
		stop()
		<-workersDone
		return err
	case <-ctx.Done():
	}

	log.Info("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Warn("http shutdown", "err", err)
	}
	<-workersDone
	return nil
}
