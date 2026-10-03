package main

import (
	"fmt"
	"log/slog"
	"os"

	"github.com/chlu-ux/quizmind/server/internal/config"
	"github.com/chlu-ux/quizmind/server/internal/llm"
	"github.com/chlu-ux/quizmind/server/internal/llm/anthropic"
)

// buildRegistry constructs one client per configured role, all sharing a Guard
// so concurrency, rate and daily-budget limits apply process-wide.
//
// A role whose API key is not set is skipped with a warning rather than
// aborting startup: the server (and admin UI) stays usable for browsing and
// review, and generation jobs fail with a clear "no client configured" error.
func buildRegistry(cfg config.Config, guard *llm.Guard, log *slog.Logger) (*llm.Registry, error) {
	reg := llm.NewRegistry()
	for name, role := range cfg.LLM.Roles {
		prov, ok := cfg.LLM.Providers[role.Provider]
		if !ok {
			return nil, fmt.Errorf("llm role %q: unknown provider %q", name, role.Provider)
		}
		var client llm.Client
		switch prov.Type {
		case "anthropic":
			key := os.Getenv(prov.APIKeyEnv)
			if key == "" {
				log.Warn("LLM role disabled: API key environment variable is empty",
					"role", name, "provider", role.Provider, "env", prov.APIKeyEnv)
				continue
			}
			c, err := anthropic.New(anthropic.Options{
				APIKey: key, BaseURL: prov.BaseURL, Model: role.Model,
				Effort: role.Effort, MaxTokens: role.MaxTokens,
			})
			if err != nil {
				return nil, fmt.Errorf("llm role %q: %w", name, err)
			}
			client = c
		case "openai_compat":
			return nil, fmt.Errorf("llm role %q: provider type openai_compat is not implemented yet (planned for M3); "+
				"use an anthropic provider for now", name)
		default:
			return nil, fmt.Errorf("llm provider %q: unknown type %q", role.Provider, prov.Type)
		}
		reg.Set(llm.Role(name), guard.Wrap(llm.Role(name), client))
		log.Info("LLM role ready", "role", name, "provider", prov.Type, "model", role.Model)
	}
	return reg, nil
}
