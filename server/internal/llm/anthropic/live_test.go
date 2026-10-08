package anthropic_test

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/chlu-ux/quizmind/server/internal/llm"
	"github.com/chlu-ux/quizmind/server/internal/llm/anthropic"
)

// TestLive_ToolLoop runs one tool round trip against a real Anthropic-protocol endpoint, to check
// that what the converser assumes (streamed events, tool arguments, thinking blocks sent back,
// usage) holds on that gateway. It is skipped unless the endpoint is given:
//
//	QUIZMIND_LIVE_KEY=sk-… QUIZMIND_LIVE_BASE_URL=https://api.deepseek.com/anthropic \
//	QUIZMIND_LIVE_MODEL=deepseek-flash go test ./internal/llm/anthropic -run Live -v
func TestLive_ToolLoop(t *testing.T) {
	key := os.Getenv("QUIZMIND_LIVE_KEY")
	if key == "" {
		t.Skip("QUIZMIND_LIVE_KEY not set")
	}
	model := os.Getenv("QUIZMIND_LIVE_MODEL")
	if model == "" {
		model = "claude-sonnet-5-5"
	}
	c, err := anthropic.New(anthropic.Options{APIKey: key, BaseURL: os.Getenv("QUIZMIND_LIVE_BASE_URL"), Model: model, MaxTokens: 2048})
	require.NoError(t, err)

	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	tools := []llm.ToolSpec{{Name: "get_weather", Description: "Get the current weather of a city.", Schema: map[string]any{
		"type": "object", "properties": map[string]any{"city": map[string]any{"type": "string"}}, "required": []string{"city"},
	}}}
	msgs := []llm.Message{{Role: "user", Blocks: []llm.Block{{Kind: llm.BlockText, Text: "What is the weather in Paris? Use the tool."}}}}

	var streamed strings.Builder
	turn, usage, err := c.Converse(ctx, llm.ChatRequest{System: []string{"You are a concise assistant."}, Messages: msgs, Tools: tools},
		func(e llm.StreamEvent) { streamed.WriteString(e.TextDelta) })
	require.NoError(t, err)
	t.Logf("turn 1: stop=%s blocks=%d usage=%+v text=%q", turn.StopReason, len(turn.Blocks), usage, turn.Text())
	require.Equal(t, llm.StopToolUse, turn.StopReason)
	assert.Equal(t, turn.Text(), streamed.String(), "streamed text equals the stored text")
	assert.NotContains(t, turn.Text(), "<ds_")
	assert.Positive(t, usage.InputTokens+usage.CachedTokens)
	assert.Positive(t, usage.OutputTokens, "final usage must carry the output tokens")

	calls := turn.ToolCalls()
	require.Len(t, calls, 1)
	assert.Equal(t, "get_weather", calls[0].ToolName)
	var args struct{ City string }
	require.NoError(t, json.Unmarshal(calls[0].ToolInput, &args), "streamed arguments assemble into valid JSON")
	assert.Contains(t, strings.ToLower(args.City), "paris")

	msgs = append(msgs,
		llm.Message{Role: "assistant", Blocks: turn.Blocks},
		llm.Message{Role: "user", Blocks: []llm.Block{{Kind: llm.BlockToolResult, ToolUseID: calls[0].ToolUseID, Text: "18C, sunny"}}})
	turn2, usage2, err := c.Converse(ctx, llm.ChatRequest{System: []string{"You are a concise assistant."}, Messages: msgs, Tools: tools}, nil)
	require.NoError(t, err, "the second turn with the first turn's blocks sent back is accepted")
	t.Logf("turn 2: stop=%s usage=%+v text=%q", turn2.StopReason, usage2, turn2.Text())
	assert.Equal(t, llm.StopEndTurn, turn2.StopReason)
	assert.Contains(t, turn2.Text(), "18")
}
