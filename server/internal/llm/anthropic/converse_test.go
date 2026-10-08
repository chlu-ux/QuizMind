package anthropic_test

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/chlu-ux/quizmind/server/internal/llm"
	"github.com/chlu-ux/quizmind/server/internal/llm/anthropic"
)

type sse struct {
	typ  string
	data any
}

// writeSSE sends events the way the Messages API streams them.
func writeSSE(w http.ResponseWriter, events ...sse) {
	w.Header().Set("Content-Type", "text/event-stream")
	for _, e := range events {
		b, _ := json.Marshal(e.data)
		fmt.Fprintf(w, "event: %s\ndata: %s\n\n", e.typ, b)
	}
}

func m(kv ...any) map[string]any {
	out := map[string]any{}
	for i := 0; i < len(kv); i += 2 {
		out[kv[i].(string)] = kv[i+1]
	}
	return out
}

func start(inputTokens, cacheRead int) sse {
	return sse{"message_start", m("type", "message_start", "message", m(
		"id", "msg_1", "type", "message", "role", "assistant", "model", "m", "content", []any{},
		"stop_reason", nil, "stop_sequence", nil,
		"usage", m("input_tokens", inputTokens, "output_tokens", 0, "cache_creation_input_tokens", 0, "cache_read_input_tokens", cacheRead),
	))}
}

func blockStart(i int, block map[string]any) sse {
	return sse{"content_block_start", m("type", "content_block_start", "index", i, "content_block", block)}
}
func blockDelta(i int, delta map[string]any) sse {
	return sse{"content_block_delta", m("type", "content_block_delta", "index", i, "delta", delta)}
}
func blockStop(i int) sse {
	return sse{"content_block_stop", m("type", "content_block_stop", "index", i)}
}
func textDelta(i int, s string) sse {
	return blockDelta(i, m("type", "text_delta", "text", s))
}
func finish(stop string, out int) []sse {
	return []sse{
		{"message_delta", m("type", "message_delta", "delta", m("stop_reason", stop, "stop_sequence", nil), "usage", m("output_tokens", out))},
		{"message_stop", m("type", "message_stop")},
	}
}

func newConverser(t *testing.T, h http.HandlerFunc) *anthropic.Client {
	t.Helper()
	return newClient(t, h)
}

func TestConverse_ToolTurnStreamsTextAndKeepsThinking(t *testing.T) {
	var body map[string]any
	c := newConverser(t, func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		require.NoError(t, json.Unmarshal(raw, &body))
		events := []sse{
			start(171, 128),
			blockStart(0, m("type", "thinking", "thinking", "", "signature", "")),
			blockDelta(0, m("type", "thinking_delta", "thinking", "Simple tool call.")),
			blockDelta(0, m("type", "signature_delta", "signature", "sig-1")),
			blockStop(0),
			blockStart(1, m("type", "text", "text", "")),
			textDelta(1, "I'll check"),
			textDelta(1, " Paris."),
			blockStop(1),
			blockStart(2, m("type", "tool_use", "id", "call_1", "name", "get_weather", "input", m())),
			blockDelta(2, m("type", "input_json_delta", "partial_json", `{"ci`)),
			blockDelta(2, m("type", "input_json_delta", "partial_json", `ty":"Paris"}`)),
			blockStop(2),
		}
		writeSSE(w, append(events, finish("tool_use", 45)...)...)
	})

	var shown strings.Builder
	turn, usage, err := c.Converse(context.Background(), llm.ChatRequest{
		System:   []string{"STABLE", "VARIABLE"},
		Messages: []llm.Message{{Role: "user", Blocks: []llm.Block{{Kind: llm.BlockText, Text: "weather?"}}}},
		Tools: []llm.ToolSpec{{Name: "get_weather", Description: "weather", Schema: map[string]any{
			"type": "object", "properties": map[string]any{"city": map[string]any{"type": "string"}}, "required": []string{"city"},
		}}},
	}, func(e llm.StreamEvent) { shown.WriteString(e.TextDelta) })
	require.NoError(t, err)

	assert.Equal(t, "I'll check Paris.", shown.String())
	assert.Equal(t, llm.StopToolUse, turn.StopReason)
	require.Len(t, turn.Blocks, 3)
	assert.Equal(t, llm.Block{Kind: llm.BlockThinking, Text: "Simple tool call.", Signature: "sig-1"}, turn.Blocks[0])
	calls := turn.ToolCalls()
	require.Len(t, calls, 1)
	assert.Equal(t, "call_1", calls[0].ToolUseID)
	assert.JSONEq(t, `{"city":"Paris"}`, string(calls[0].ToolInput))
	assert.Equal(t, llm.Usage{InputTokens: 171, OutputTokens: 45, CachedTokens: 128}, usage)

	// Request: streamed, tools declared, no tool_choice, effort from the options, cache on the stable block.
	assert.Equal(t, true, body["stream"])
	assert.NotContains(t, body, "tool_choice")
	tools := body["tools"].([]any)
	require.Len(t, tools, 1)
	assert.Equal(t, "get_weather", tools[0].(map[string]any)["name"])
	assert.Equal(t, "medium", body["output_config"].(map[string]any)["effort"])
	system := body["system"].([]any)
	require.Len(t, system, 2)
	assert.Contains(t, system[0], "cache_control")
	assert.NotContains(t, system[1], "cache_control")
}

func TestConverse_ReplaysThinkingAndToolResult(t *testing.T) {
	var body map[string]any
	c := newConverser(t, func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		require.NoError(t, json.Unmarshal(raw, &body))
		writeSSE(w, append([]sse{start(10, 0), blockStart(0, m("type", "text", "text", "")), textDelta(0, "ok"), blockStop(0)}, finish("end_turn", 1)...)...)
	})
	_, _, err := c.Converse(context.Background(), llm.ChatRequest{Messages: []llm.Message{
		{Role: "user", Blocks: []llm.Block{{Kind: llm.BlockText, Text: "weather?"}}},
		{Role: "assistant", Blocks: []llm.Block{
			{Kind: llm.BlockThinking, Text: "hmm", Signature: "sig-1"},
			{Kind: llm.BlockToolUse, ToolUseID: "call_1", ToolName: "get_weather", ToolInput: json.RawMessage(`{"city":"Paris"}`)},
		}},
		{Role: "user", Blocks: []llm.Block{{Kind: llm.BlockToolResult, ToolUseID: "call_1", Text: "18C", IsError: false}}},
	}}, nil)
	require.NoError(t, err)

	msgs := body["messages"].([]any)
	require.Len(t, msgs, 3)
	asst := msgs[1].(map[string]any)["content"].([]any)
	assert.Equal(t, "thinking", asst[0].(map[string]any)["type"])
	assert.Equal(t, "sig-1", asst[0].(map[string]any)["signature"])
	assert.Equal(t, "hmm", asst[0].(map[string]any)["thinking"])
	assert.Equal(t, "tool_use", asst[1].(map[string]any)["type"])
	assert.Equal(t, map[string]any{"city": "Paris"}, asst[1].(map[string]any)["input"])
	res := msgs[2].(map[string]any)["content"].([]any)[0].(map[string]any)
	assert.Equal(t, "tool_result", res["type"])
	assert.Equal(t, "call_1", res["tool_use_id"])
}

func TestConverse_StripsGatewayNoiseSplitAcrossDeltas(t *testing.T) {
	c := newConverser(t, func(w http.ResponseWriter, r *http.Request) {
		writeSSE(w, append([]sse{
			start(5, 0),
			blockStart(0, m("type", "text", "text", "")),
			textDelta(0, "Hi! What's on your"),
			textDelta(0, " mind?<ds_"),
			textDelta(0, "safety>[用户未成年]否[规则]无</ds_saf"),
			textDelta(0, "ety>Sa"),
			textDelta(0, "fe"),
			blockStop(0),
		}, finish("end_turn", 20)...)...)
	})
	var shown strings.Builder
	turn, _, err := c.Converse(context.Background(), llm.ChatRequest{
		Messages: []llm.Message{{Role: "user", Blocks: []llm.Block{{Kind: llm.BlockText, Text: "hi"}}}},
	}, func(e llm.StreamEvent) { shown.WriteString(e.TextDelta) })
	require.NoError(t, err)
	assert.Equal(t, "Hi! What's on your mind?", shown.String())
	assert.Equal(t, "Hi! What's on your mind?", turn.Text(), "the history must not carry the noise either")
}

func TestConverse_MaxTokensDropsCutOffToolCall(t *testing.T) {
	c := newConverser(t, func(w http.ResponseWriter, r *http.Request) {
		writeSSE(w, append([]sse{
			start(5, 0),
			blockStart(0, m("type", "text", "text", "")),
			textDelta(0, "partial"),
			blockStop(0),
			blockStart(1, m("type", "tool_use", "id", "call_1", "name", "t", "input", m())),
			blockDelta(1, m("type", "input_json_delta", "partial_json", `{"a":`)),
			blockStop(1),
		}, finish("max_tokens", 99)...)...)
	})
	turn, usage, err := c.Converse(context.Background(), llm.ChatRequest{
		Messages: []llm.Message{{Role: "user", Blocks: []llm.Block{{Kind: llm.BlockText, Text: "go"}}}},
	}, nil)
	require.ErrorIs(t, err, llm.ErrTruncated)
	assert.Equal(t, "partial", turn.Text())
	assert.Empty(t, turn.ToolCalls())
	assert.EqualValues(t, 99, usage.OutputTokens)
}

func TestConverse_HTTPErrorIsReported(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"type":"error","error":{"type":"invalid_request_error","message":"nope"}}`))
	}))
	t.Cleanup(ts.Close)
	c, err := anthropic.New(anthropic.Options{APIKey: "k", BaseURL: ts.URL, Model: "m", MaxTokens: 100})
	require.NoError(t, err)
	_, _, err = c.Converse(context.Background(), llm.ChatRequest{
		Messages: []llm.Message{{Role: "user", Blocks: []llm.Block{{Kind: llm.BlockText, Text: "go"}}}},
	}, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "nope")
}

func TestConverse_NoiseIsFilteredEvenWithoutAListener(t *testing.T) {
	c := newConverser(t, func(w http.ResponseWriter, r *http.Request) {
		writeSSE(w, append([]sse{
			start(5, 0),
			blockStart(0, m("type", "text", "text", "")),
			textDelta(0, "pong<ds_safety>x</ds_safety>Safe"),
			blockStop(0),
		}, finish("end_turn", 2)...)...)
	})
	turn, _, err := c.Converse(context.Background(), llm.ChatRequest{
		Messages: []llm.Message{{Role: "user", Blocks: []llm.Block{{Kind: llm.BlockText, Text: "hi"}}}},
	}, nil)
	require.NoError(t, err)
	assert.Equal(t, "pong", turn.Text())
}

func TestConverse_SendsImagesAsBase64Blocks(t *testing.T) {
	var body map[string]any
	c := newConverser(t, func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		require.NoError(t, json.Unmarshal(raw, &body))
		writeSSE(w, append([]sse{start(10, 0), blockStart(0, m("type", "text", "text", "")), textDelta(0, "ok"), blockStop(0)}, finish("end_turn", 1)...)...)
	})
	_, _, err := c.Converse(context.Background(), llm.ChatRequest{Messages: []llm.Message{
		{Role: "user", Blocks: []llm.Block{
			{Kind: llm.BlockImage, MediaType: "image/png", Data: []byte("png-bytes")},
			{Kind: llm.BlockText, Text: "what is this?"},
		}},
	}}, nil)
	require.NoError(t, err)

	content := body["messages"].([]any)[0].(map[string]any)["content"].([]any)
	require.Len(t, content, 2)
	img := content[0].(map[string]any)
	assert.Equal(t, "image", img["type"])
	src := img["source"].(map[string]any)
	assert.Equal(t, "base64", src["type"])
	assert.Equal(t, "image/png", src["media_type"])
	assert.Equal(t, "cG5nLWJ5dGVz", src["data"])
	assert.Equal(t, "text", content[1].(map[string]any)["type"])
}
