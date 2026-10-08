package service_test

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/chlu-ux/quizmind/server/internal/llm"
	"github.com/chlu-ux/quizmind/server/internal/service"
)

func TestDeviceUsageDoesNotUseUpTheServersBudget(t *testing.T) {
	svc := bareService(t)
	ctx := context.Background()
	p, err := svc.CreateProvider(ctx, service.ProviderInput{Name: "P", Protocol: "openai", BaseURL: "https://x/v1", APIKey: "k"})
	require.NoError(t, err)
	m, err := svc.CreateModel(ctx, service.ModelInput{ProviderID: p.ID, Model: "m"})
	require.NoError(t, err)
	_, err = svc.SaveRoles(ctx, map[string]string{"explain": m.ID})
	require.NoError(t, err)
	_, err = svc.SaveAIConfig(ctx, service.AIConfigUpdate{Enabled: true, AppToken: "tok1"})
	require.NoError(t, err)

	res, err := svc.UploadAIUsage(ctx, "tok1", []service.UsageIn{{
		ID: "u1", Model: "m", InputTokens: 900_000, OutputTokens: 300_000, OK: true, CreatedAt: time.Now().UnixMilli(),
	}})
	require.NoError(t, err)
	assert.Equal(t, 1, res.Accepted)

	// The phone already spent those tokens; the budget only limits what the server itself would spend.
	rec := service.LLMRecorder{DB: svc.DB}
	used, err := rec.TokensSince(ctx, time.Now().Add(-time.Hour))
	require.NoError(t, err)
	assert.EqualValues(t, 0, used)

	require.NoError(t, rec.Record(ctx, llm.CallRecord{Role: llm.RoleGenerator, Provider: "anthropic", Model: "c",
		Usage: llm.Usage{InputTokens: 70, OutputTokens: 30}, OccurredAt: time.Now()}))
	used, err = rec.TokensSince(ctx, time.Now().Add(-time.Hour))
	require.NoError(t, err)
	assert.EqualValues(t, 100, used)

	_, err = svc.UploadAIUsage(ctx, "nope", nil)
	assert.ErrorIs(t, err, service.ErrUnauthorized)
}
