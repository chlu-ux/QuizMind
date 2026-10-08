package openaicompat_test

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/chlu-ux/quizmind/server/internal/llm"
	"github.com/chlu-ux/quizmind/server/internal/llm/openaicompat"
)

func reply(content, finish string) map[string]any {
	return map[string]any{
		"choices": []map[string]any{{"message": map[string]any{"content": content}, "finish_reason": finish}},
		"usage": map[string]any{
			"prompt_tokens": 100, "completion_tokens": 20,
			"prompt_tokens_details": map[string]any{"cached_tokens": 40},
		},
	}
}

func newClient(t *testing.T, h http.HandlerFunc) *openaicompat.Client {
	t.Helper()
	ts := httptest.NewServer(h)
	t.Cleanup(ts.Close)
	c, err := openaicompat.New(openaicompat.Options{APIKey: "k", BaseURL: ts.URL + "/v1/", Model: "m", Temperature: 0.2})
	require.NoError(t, err)
	return c
}

var req = llm.JSONRequest{
	System: "SYS", User: "USER", SchemaName: "things",
	Schema: map[string]any{"type": "object"},
}

func TestGenerateJSON_SchemaMode(t *testing.T) {
	var got map[string]any
	c := newClient(t, func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, "/v1/chat/completions", r.URL.Path)
		assert.Equal(t, "Bearer k", r.Header.Get("Authorization"))
		b, _ := io.ReadAll(r.Body)
		require.NoError(t, json.Unmarshal(b, &got))
		_ = json.NewEncoder(w).Encode(reply(`{"n":3}`, "stop"))
	})
	var out struct{ N int }
	u, err := c.GenerateJSON(context.Background(), req, &out)
	require.NoError(t, err)
	assert.Equal(t, 3, out.N)
	assert.EqualValues(t, 60, u.InputTokens, "cached tokens are not input")
	assert.EqualValues(t, 40, u.CachedTokens)
	assert.EqualValues(t, 20, u.OutputTokens)
	rf := got["response_format"].(map[string]any)
	assert.Equal(t, "json_schema", rf["type"])
	assert.EqualValues(t, 0.2, got["temperature"])
}

func TestGenerateJSON_FallsBackAndRemembers(t *testing.T) {
	var calls, schemaTries atomic.Int32
	c := newClient(t, func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		var body map[string]any
		b, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(b, &body)
		if rf, ok := body["response_format"].(map[string]any); ok && rf["type"] == "json_schema" {
			schemaTries.Add(1)
			http.Error(w, `{"error":"unsupported response_format"}`, http.StatusBadRequest)
			return
		}
		_ = json.NewEncoder(w).Encode(reply("```json\n{\"n\":7}\n```", "stop"))
	})
	var out struct{ N int }
	_, err := c.GenerateJSON(context.Background(), req, &out)
	require.NoError(t, err)
	assert.Equal(t, 7, out.N)
	_, err = c.GenerateJSON(context.Background(), req, &out)
	require.NoError(t, err)
	assert.EqualValues(t, 1, schemaTries.Load(), "json_schema is only tried once")
	assert.EqualValues(t, 3, calls.Load())
}

func TestGenerateJSON_Errors(t *testing.T) {
	t.Run("truncated", func(t *testing.T) {
		c := newClient(t, func(w http.ResponseWriter, _ *http.Request) { _ = json.NewEncoder(w).Encode(reply(`{"n":`, "length")) })
		_, err := c.GenerateJSON(context.Background(), req, &struct{}{})
		assert.ErrorIs(t, err, llm.ErrTruncated)
	})
	t.Run("auth failure is final", func(t *testing.T) {
		var n atomic.Int32
		c := newClient(t, func(w http.ResponseWriter, _ *http.Request) {
			n.Add(1)
			http.Error(w, "bad key", http.StatusUnauthorized)
		})
		_, err := c.GenerateJSON(context.Background(), req, &struct{}{})
		require.Error(t, err)
		assert.Contains(t, err.Error(), "401")
		assert.EqualValues(t, 1, n.Load())
	})
	t.Run("no json in reply", func(t *testing.T) {
		c := newClient(t, func(w http.ResponseWriter, _ *http.Request) { _ = json.NewEncoder(w).Encode(reply("sorry", "stop")) })
		_, err := c.GenerateJSON(context.Background(), req, &struct{}{})
		assert.Error(t, err)
	})
}

func TestPing(t *testing.T) {
	c := newClient(t, func(w http.ResponseWriter, _ *http.Request) { _ = json.NewEncoder(w).Encode(reply("pong", "stop")) })
	got, err := c.Ping(context.Background())
	require.NoError(t, err)
	assert.Equal(t, "pong", got)
}
