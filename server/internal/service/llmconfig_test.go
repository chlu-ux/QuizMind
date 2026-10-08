package service_test

import (
	"context"
	"io"
	"log/slog"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/chlu-ux/quizmind/server/internal/config"
	"github.com/chlu-ux/quizmind/server/internal/db"
	"github.com/chlu-ux/quizmind/server/internal/events"
	"github.com/chlu-ux/quizmind/server/internal/jobs"
	"github.com/chlu-ux/quizmind/server/internal/llm"
	"github.com/chlu-ux/quizmind/server/internal/service"
	"github.com/chlu-ux/quizmind/server/internal/store"
)

func bareService(t *testing.T) *service.Service {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "app.db"))
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	return service.New(d, config.Default(), llm.NewRegistry(), jobs.NewQueue(d), events.NewHub(), log)
}

func TestSeedLLMConfigImportsTheOldSettings(t *testing.T) {
	t.Setenv("ANTHROPIC_API_KEY", "sk-ant-from-env")
	svc := bareService(t)
	ctx := context.Background()

	// The AI-explanation endpoint as it used to be stored: connection details and all.
	legacy := `{"enabled":true,"base_url":"https://api.example.com/v1","api_key":"sk-explain","model":"gpt-x",` +
		`"max_tokens":1200,"temperature":0.4,"app_token":"tok1"}`
	require.NoError(t, store.New(svc.DB.Write).PutSetting(ctx, store.PutSettingParams{Key: "ai", Value: legacy}))

	require.NoError(t, svc.SeedLLMConfig(ctx))
	require.NoError(t, svc.ReloadLLM(ctx))

	v, err := svc.LLMConfig(ctx)
	require.NoError(t, err)
	require.Len(t, v.Providers, 2)
	require.Len(t, v.Models, 2)
	byName := map[string]service.ProviderView{}
	for _, p := range v.Providers {
		byName[p.Name] = p
		assert.True(t, p.APIKeySet)
	}
	assert.Equal(t, "anthropic", byName["Anthropic"].Protocol)
	assert.Equal(t, "openai", byName["AI 解读"].Protocol)

	// The generator role keeps working as before: the model and effort from config.yaml's defaults.
	gen := modelByID(v, v.Roles["generator"])
	assert.Equal(t, "claude-sonnet-5-5", gen.Model)
	assert.Equal(t, "medium", gen.Effort)
	_, err = svc.LLM.For(llm.RoleGenerator)
	assert.NoError(t, err, "the generator client is built from the imported provider")
	_, err = svc.LLM.For(llm.RoleAgent)
	assert.Error(t, err, "roles that were never configured stay unbound")

	// The apps still get the same endpoint, now taken from the model bound to the explain role.
	cfg, err := svc.AppAIConfig(ctx, "tok1")
	require.NoError(t, err)
	assert.Equal(t, service.AppAIConfig{BaseURL: "https://api.example.com/v1", APIKey: "sk-explain",
		Model: "gpt-x", MaxTokens: 1200, Temperature: 0.4}, cfg)
	ai, err := svc.AdminAIConfig(ctx)
	require.NoError(t, err)
	assert.True(t, ai.Enabled)
	assert.True(t, ai.Ready)
	assert.Equal(t, "AI 解读 / gpt-x", ai.ModelName)

	// The old settings are gone from the stored AI config, and the import never runs twice.
	raw, err := svc.DB.Read.QueryContext(ctx, `SELECT value FROM app_setting WHERE key = 'ai'`)
	require.NoError(t, err)
	defer raw.Close()
	require.True(t, raw.Next())
	var stored string
	require.NoError(t, raw.Scan(&stored))
	assert.NotContains(t, stored, "sk-explain")

	for _, p := range v.Providers {
		for _, m := range v.Models {
			if m.ProviderID == p.ID {
				v.Roles = map[string]string{}
				_, err = svc.SaveRoles(ctx, v.Roles)
				require.NoError(t, err)
				require.NoError(t, svc.DeleteModel(ctx, m.ID))
			}
		}
		require.NoError(t, svc.DeleteProvider(ctx, p.ID))
	}
	require.NoError(t, svc.SeedLLMConfig(ctx))
	v, err = svc.LLMConfig(ctx)
	require.NoError(t, err)
	assert.Empty(t, v.Providers, "deleting everything does not bring the old settings back")
}

func TestSeedLLMConfigWithoutAnyOldSettings(t *testing.T) {
	t.Setenv("ANTHROPIC_API_KEY", "")
	svc := bareService(t)
	ctx := context.Background()
	require.NoError(t, svc.SeedLLMConfig(ctx))
	require.NoError(t, svc.ReloadLLM(ctx))
	v, err := svc.LLMConfig(ctx)
	require.NoError(t, err)
	assert.Empty(t, v.Providers)
	assert.Empty(t, v.Roles)
	assert.Equal(t, 2, v.Limits.MaxConcurrency)
	_, err = svc.LLM.For(llm.RoleGenerator)
	assert.Error(t, err)
}

func TestReloadAppliesEditsWithoutARestart(t *testing.T) {
	svc := bareService(t)
	ctx := context.Background()

	p, err := svc.CreateProvider(ctx, service.ProviderInput{Name: "A", Protocol: "anthropic", APIKey: "sk-1"})
	require.NoError(t, err)
	m, err := svc.CreateModel(ctx, service.ModelInput{ProviderID: p.ID, Model: "claude-x"})
	require.NoError(t, err)
	assert.Equal(t, 8000, m.MaxTokens, "default output cap")
	assert.Equal(t, "claude-x", m.Name, "the name defaults to the model id")

	_, err = svc.LLM.For(llm.RoleGenerator)
	require.Error(t, err)
	_, err = svc.SaveRoles(ctx, map[string]string{"generator": m.ID, "agent": m.ID})
	require.NoError(t, err)
	c, err := svc.LLM.For(llm.RoleGenerator)
	require.NoError(t, err)
	assert.Equal(t, "claude-x", c.Model())
	_, err = svc.LLM.For(llm.RoleAgent)
	assert.NoError(t, err)

	// Editing the model rebuilds the client with the new id.
	_, err = svc.UpdateModel(ctx, m.ID, service.ModelInput{ProviderID: p.ID, Model: "claude-y"})
	require.NoError(t, err)
	c, _ = svc.LLM.For(llm.RoleGenerator)
	assert.Equal(t, "claude-y", c.Model())

	// Unbinding a role takes its client away.
	_, err = svc.SaveRoles(ctx, map[string]string{"generator": m.ID})
	require.NoError(t, err)
	_, err = svc.LLM.For(llm.RoleAgent)
	assert.Error(t, err)

	// The explain role is for the apps: it never gets a server-side client.
	o, err := svc.CreateProvider(ctx, service.ProviderInput{Name: "O", Protocol: "openai", BaseURL: "https://x/v1", APIKey: "k"})
	require.NoError(t, err)
	om, err := svc.CreateModel(ctx, service.ModelInput{ProviderID: o.ID, Model: "m"})
	require.NoError(t, err)
	_, err = svc.SaveRoles(ctx, map[string]string{"generator": m.ID, "explain": om.ID})
	require.NoError(t, err)
	_, err = svc.LLM.For(llm.RoleExplain)
	assert.Error(t, err)
}

func modelByID(v service.LLMConfigView, id string) service.ModelView {
	for _, m := range v.Models {
		if m.ID == id {
			return m
		}
	}
	return service.ModelView{}
}

func TestModelVisionFollowsTheAssistantModel(t *testing.T) {
	svc := bareService(t)
	ctx := context.Background()

	p, err := svc.CreateProvider(ctx, service.ProviderInput{Name: "A", Protocol: "anthropic", APIKey: "sk-1"})
	require.NoError(t, err)
	plain, err := svc.CreateModel(ctx, service.ModelInput{ProviderID: p.ID, Model: "text-only"})
	require.NoError(t, err)
	assert.False(t, plain.Vision, "off unless the admin says the model can see")
	seeing, err := svc.CreateModel(ctx, service.ModelInput{ProviderID: p.ID, Model: "can-see", Vision: true})
	require.NoError(t, err)
	assert.True(t, seeing.Vision)

	status := func() service.AgentStatus {
		t.Helper()
		st, err := svc.AgentStatus(ctx, "tok-1234")
		require.NoError(t, err)
		return st
	}
	_, err = svc.SaveAIConfig(ctx, service.AIConfigUpdate{AppToken: "tok-1234"})
	require.NoError(t, err)
	_, err = svc.SaveRoles(ctx, map[string]string{"agent": plain.ID})
	require.NoError(t, err)
	assert.False(t, status().Vision)

	_, err = svc.SaveRoles(ctx, map[string]string{"agent": seeing.ID})
	require.NoError(t, err)
	assert.True(t, status().Vision)

	// Switching the flag off takes effect at once, without rebinding the role.
	_, err = svc.UpdateModel(ctx, seeing.ID, service.ModelInput{ProviderID: p.ID, Model: "can-see", Vision: false})
	require.NoError(t, err)
	assert.False(t, status().Vision)
}
