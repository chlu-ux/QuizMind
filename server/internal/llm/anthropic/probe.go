package anthropic

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/chlu-ux/quizmind/server/internal/llm"
)

var _ llm.Prober = (*Client)(nil)

// Probe checks what the assistant needs from an endpoint: streamed text, a tool call with valid
// arguments, a second request that sends the first answer back (thinking blocks included) with a
// tool result, and a reply free of the gateway's internal markers. Gateways that speak the
// Anthropic protocol differ most on exactly these.
func (c *Client) Probe(ctx context.Context) []llm.Check {
	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()

	var checks []llm.Check
	add := func(name string, ok bool, detail string) {
		checks = append(checks, llm.Check{Name: name, OK: ok, Detail: detail})
	}
	noiseBefore := c.noiseSeen.Load()

	// 1. Streamed text.
	turn, _, err := c.Converse(ctx, llm.ChatRequest{
		Messages:  []llm.Message{{Role: "user", Blocks: []llm.Block{{Kind: llm.BlockText, Text: "Reply with the single word: pong"}}}},
		MaxTokens: 512,
	}, nil)
	switch {
	case err != nil:
		add("流式输出", false, errText(err))
		return checks // nothing else can work
	case strings.TrimSpace(turn.Text()) == "":
		add("流式输出", false, "模型没有返回文字")
	default:
		add("流式输出", true, "")
	}

	// 2. A tool call.
	echo := llm.ToolSpec{Name: "echo", Description: "Repeat the given text back. Always call this tool when asked to echo.", Schema: map[string]any{
		"type": "object", "properties": map[string]any{"text": map[string]any{"type": "string", "description": "the text to repeat"}}, "required": []string{"text"},
	}}
	history := []llm.Message{{Role: "user", Blocks: []llm.Block{{Kind: llm.BlockText, Text: `Call the echo tool with the text "ok". Do not answer in words before calling it.`}}}}
	turn, _, err = c.Converse(ctx, llm.ChatRequest{Messages: history, Tools: []llm.ToolSpec{echo}, MaxTokens: 1024}, nil)
	var calls []llm.Block
	if err == nil {
		calls = turn.ToolCalls()
	}
	switch {
	case err != nil:
		add("工具调用", false, errText(err))
		return checks
	case len(calls) == 0:
		add("工具调用", false, "模型没有调用工具（停止原因："+turn.StopReason+"）")
		return checks
	default:
		var args struct{ Text string }
		if jerr := json.Unmarshal(calls[0].ToolInput, &args); jerr != nil || calls[0].ToolName != "echo" {
			add("工具调用", false, fmt.Sprintf("工具参数不合法：%s", calls[0].ToolInput))
			return checks
		}
		add("工具调用", true, "")
	}

	// 3. Send the first answer back, thinking blocks and all, with the tool's result.
	history = append(history,
		llm.Message{Role: "assistant", Blocks: turn.Blocks},
		llm.Message{Role: "user", Blocks: []llm.Block{{Kind: llm.BlockToolResult, ToolUseID: calls[0].ToolUseID, Text: "ok"}}})
	turn2, _, err := c.Converse(ctx, llm.ChatRequest{Messages: history, Tools: []llm.ToolSpec{echo}, MaxTokens: 1024}, nil)
	switch {
	case err != nil:
		add("多轮工具往返", false, errText(err))
	case strings.TrimSpace(turn2.Text()) == "" && len(turn2.ToolCalls()) == 0:
		add("多轮工具往返", false, "第二轮没有返回内容")
	default:
		add("多轮工具往返", true, "")
	}

	// 4. Markers leaking into the text are removed, but they may cut replies short.
	if c.noiseSeen.Load() > noiseBefore {
		add("正文干净", false, "网关把内部标记混进了回答（如 <ds_safety>），已自动过滤；偶尔可能导致回答被截短")
	} else {
		add("正文干净", true, "")
	}
	return checks
}

func errText(err error) string {
	s := err.Error()
	if len(s) > 300 {
		s = s[:300] + "…"
	}
	return s
}
