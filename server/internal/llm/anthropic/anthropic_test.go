package anthropic_test

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/chlu-ux/quizmind/server/internal/llm"
	"github.com/chlu-ux/quizmind/server/internal/llm/anthropic"
)

// messageResponse builds a minimal Messages API response.
func messageResponse(stopReason, text string) map[string]any {
	return map[string]any{
		"id": "msg_test", "type": "message", "role": "assistant", "model": "claude-sonnet-5-5",
		"content":     []map[string]any{{"type": "text", "text": text}},
		"stop_reason": stopReason, "stop_sequence": nil,
		"usage": map[string]any{
			"input_tokens": 120, "output_tokens": 45,
			"cache_creation_input_tokens": 10, "cache_read_input_tokens": 300,
		},
	}
}

func newClient(t *testing.T, handler http.HandlerFunc) *anthropic.Client {
	t.Helper()
	ts := httptest.NewServer(handler)
	t.Cleanup(ts.Close)
	c, err := anthropic.New(anthropic.Options{
		APIKey: "test-key", BaseURL: ts.URL, Model: "claude-sonnet-5-5", Effort: "medium", MaxTokens: 4096,
	})
	require.NoError(t, err)
	return c
}

func TestGenerateJSON_RequestShapeAndParsing(t *testing.T) {
	var got map[string]any
	var apiKey string
	c := newClient(t, func(w http.ResponseWriter, r *http.Request) {
		apiKey = r.Header.Get("X-Api-Key")
		assert.Equal(t, "/v1/messages", r.URL.Path)
		body, _ := io.ReadAll(r.Body)
		require.NoError(t, json.Unmarshal(body, &got))
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(messageResponse("end_turn", `{"questions":[{"stem":"题干"}]}`))
	})

	var out struct {
		Questions []struct{ Stem string } `json:"questions"`
	}
	schema := map[string]any{"type": "object", "properties": map[string]any{"questions": map[string]any{"type": "array"}}}
	usage, err := c.GenerateJSON(context.Background(), llm.JSONRequest{
		System: "SYSTEM PROMPT", User: "USER PROMPT", Schema: schema,
	}, &out)
	require.NoError(t, err)
	require.Len(t, out.Questions, 1)
	assert.Equal(t, "题干", out.Questions[0].Stem)

	// Usage: cache creation counts as input, cache reads are reported separately.
	assert.EqualValues(t, 130, usage.InputTokens)
	assert.EqualValues(t, 45, usage.OutputTokens)
	assert.EqualValues(t, 300, usage.CachedTokens)

	assert.Equal(t, "test-key", apiKey)
	assert.Equal(t, "claude-sonnet-5-5", got["model"])
	assert.EqualValues(t, 4096, got["max_tokens"], "falls back to the configured cap")

	// Sonnet 5.5 rejects forced tool use and non-default sampling params.
	assert.NotContains(t, got, "tool_choice")
	assert.NotContains(t, got, "tools")
	assert.NotContains(t, got, "temperature")
	assert.NotContains(t, got, "top_p")
	assert.NotContains(t, got, "thinking", "thinking is left at the model default")

	oc, ok := got["output_config"].(map[string]any)
	require.True(t, ok, "structured output goes through output_config")
	assert.Equal(t, "medium", oc["effort"])
	format := oc["format"].(map[string]any)
	assert.Equal(t, "json_schema", format["type"])
	assert.Equal(t, schema, format["schema"])

	system := got["system"].([]any)
	require.Len(t, system, 1)
	sys := system[0].(map[string]any)
	assert.Equal(t, "SYSTEM PROMPT", sys["text"])
	assert.Contains(t, sys, "cache_control", "stable system prompt is marked cacheable")

	msgs := got["messages"].([]any)
	require.Len(t, msgs, 1)
	assert.Contains(t, mustJSON(msgs[0]), "USER PROMPT")
}

func TestGenerateJSON_StopReasons(t *testing.T) {
	cases := map[string]struct {
		stop string
		text string
		want error
	}{
		"truncated": {"max_tokens", `{"questions":[`, llm.ErrTruncated},
		"refusal":   {"refusal", "", llm.ErrRefused},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			c := newClient(t, func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				_ = json.NewEncoder(w).Encode(messageResponse(tc.stop, tc.text))
			})
			var out map[string]any
			usage, err := c.GenerateJSON(context.Background(), llm.JSONRequest{}, &out)
			assert.ErrorIs(t, err, tc.want)
			assert.EqualValues(t, 45, usage.OutputTokens, "tokens are still reported so spend is tracked")
		})
	}
}

func TestGenerateJSON_BadOutputAndAPIErrors(t *testing.T) {
	c := newClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(messageResponse("end_turn", "this is not json"))
	})
	var out map[string]any
	_, err := c.GenerateJSON(context.Background(), llm.JSONRequest{}, &out)
	assert.ErrorContains(t, err, "decode structured output")

	c = newClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"type":"error","error":{"type":"invalid_request_error","message":"bad schema"}}`))
	})
	_, err = c.GenerateJSON(context.Background(), llm.JSONRequest{}, &out)
	assert.ErrorContains(t, err, "bad schema")
}

func TestNew_RequiresKeyAndModel(t *testing.T) {
	_, err := anthropic.New(anthropic.Options{Model: "m"})
	assert.Error(t, err)
	_, err = anthropic.New(anthropic.Options{APIKey: "k"})
	assert.Error(t, err)
}

func mustJSON(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}
