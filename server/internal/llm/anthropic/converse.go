package anthropic

import (
	"context"
	"encoding/json"
	"fmt"

	sdk "github.com/anthropics/anthropic-sdk-go"

	"github.com/chlu-ux/quizmind/server/internal/llm"
)

var _ llm.Converser = (*Client)(nil)

// Converse streams one turn. tool_choice is never sent (this model family refuses any/tool, and
// some gateways refuse more), so the model decides on its own whether to call a tool.
//
// Thinking blocks come back in the turn and must be sent back with it unchanged. Text is passed
// through llm.NoiseFilter before it is shown or stored, because some gateways leak internal
// markers into it.
func (c *Client) Converse(ctx context.Context, req llm.ChatRequest, emit func(llm.StreamEvent)) (llm.ChatTurn, llm.Usage, error) {
	params, err := c.chatParams(req)
	if err != nil {
		return llm.ChatTurn{}, llm.Usage{}, err
	}

	stream := c.c.Messages.NewStreaming(ctx, params)
	defer stream.Close()

	var msg sdk.Message
	var filter llm.NoiseFilter // the text block being streamed
	for stream.Next() {
		ev := stream.Current()
		if err := msg.Accumulate(ev); err != nil {
			return llm.ChatTurn{}, usageOf(&msg), fmt.Errorf("anthropic stream: %w", err)
		}
		switch ev.Type {
		case "content_block_start":
			filter = llm.NoiseFilter{}
		case "content_block_delta":
			if ev.Delta.Type == "text_delta" {
				if s := filter.Write(ev.Delta.Text); s != "" && emit != nil {
					emit(llm.StreamEvent{TextDelta: s})
				}
			}
		case "content_block_stop":
			s := filter.Flush()
			if emit != nil && s != "" {
				emit(llm.StreamEvent{TextDelta: s})
			}
			if filter.Dropped() {
				c.noiseSeen.Add(1)
			}
		}
	}
	usage := usageOf(&msg)
	if err := stream.Err(); err != nil {
		return llm.ChatTurn{}, usage, fmt.Errorf("anthropic stream: %w", err)
	}
	if msg.ID == "" {
		return llm.ChatTurn{}, usage, fmt.Errorf("anthropic stream: ended without a message")
	}

	turn, err := turnOf(&msg)
	if err != nil {
		return llm.ChatTurn{}, usage, err
	}
	switch turn.StopReason {
	case llm.StopRefusal:
		return turn, usage, fmt.Errorf("%w: category=%q", llm.ErrRefused, msg.StopDetails.Category)
	case llm.StopMaxTokens:
		// The partial answer is still returned; its tool calls were dropped in turnOf.
		return turn, usage, llm.ErrTruncated
	}
	return turn, usage, nil
}

func usageOf(m *sdk.Message) llm.Usage {
	return llm.Usage{
		InputTokens:  m.Usage.InputTokens + m.Usage.CacheCreationInputTokens,
		OutputTokens: m.Usage.OutputTokens,
		CachedTokens: m.Usage.CacheReadInputTokens,
	}
}

func (c *Client) chatParams(req llm.ChatRequest) (sdk.MessageNewParams, error) {
	maxTokens := req.MaxTokens
	if maxTokens <= 0 {
		maxTokens = c.opts.MaxTokens
	}
	params := sdk.MessageNewParams{Model: sdk.Model(c.opts.Model), MaxTokens: int64(maxTokens)}
	if c.opts.Effort != "" {
		params.OutputConfig = sdk.OutputConfigParam{Effort: sdk.OutputConfigEffort(c.opts.Effort)}
	}

	for _, s := range req.System {
		if s == "" {
			continue
		}
		params.System = append(params.System, sdk.TextBlockParam{Text: s})
	}
	// The first system block is the stable one: put the cache breakpoint after it. Gateways that
	// ignore the breakpoint still cache by prefix, so the stable text stays first.
	if len(params.System) > 0 {
		params.System[0].CacheControl = sdk.NewCacheControlEphemeralParam()
	}

	for _, t := range req.Tools {
		schema := sdk.ToolInputSchemaParam{Properties: t.Schema["properties"]}
		if r, ok := t.Schema["required"].([]string); ok {
			schema.Required = r
		}
		params.Tools = append(params.Tools, sdk.ToolUnionParam{OfTool: &sdk.ToolParam{
			Name: t.Name, Description: sdk.String(t.Description), InputSchema: schema,
		}})
	}

	for _, m := range req.Messages {
		blocks, err := blocksToParams(m.Blocks)
		if err != nil {
			return params, err
		}
		if len(blocks) == 0 {
			continue
		}
		switch m.Role {
		case "user":
			params.Messages = append(params.Messages, sdk.NewUserMessage(blocks...))
		case "assistant":
			params.Messages = append(params.Messages, sdk.NewAssistantMessage(blocks...))
		default:
			return params, fmt.Errorf("anthropic: unknown message role %q", m.Role)
		}
	}
	if len(params.Messages) == 0 {
		return params, fmt.Errorf("anthropic: no messages")
	}
	return params, nil
}

func blocksToParams(blocks []llm.Block) ([]sdk.ContentBlockParamUnion, error) {
	var out []sdk.ContentBlockParamUnion
	for _, b := range blocks {
		switch b.Kind {
		case llm.BlockText:
			if b.Text != "" {
				out = append(out, sdk.NewTextBlock(b.Text))
			}
		case llm.BlockThinking:
			out = append(out, sdk.NewThinkingBlock(b.Signature, b.Text))
		case llm.BlockToolUse:
			var input any = map[string]any{}
			if len(b.ToolInput) > 0 {
				input = json.RawMessage(b.ToolInput)
			}
			out = append(out, sdk.NewToolUseBlock(b.ToolUseID, input, b.ToolName))
		case llm.BlockToolResult:
			out = append(out, sdk.NewToolResultBlock(b.ToolUseID, b.Text, b.IsError))
		default:
			return nil, fmt.Errorf("anthropic: unknown block kind %q", b.Kind)
		}
	}
	return out, nil
}

// turnOf converts the accumulated message into blocks. Text is cleaned of gateway noise, text that
// is empty afterwards is dropped. Tool calls of a turn cut off by max_tokens are dropped, since
// their arguments may be incomplete; a finished turn whose arguments are not valid JSON is an error.
func turnOf(m *sdk.Message) (llm.ChatTurn, error) {
	turn := llm.ChatTurn{StopReason: string(m.StopReason)}
	for _, b := range m.Content {
		switch b.Type {
		case "text":
			if t := llm.StripNoise(b.Text); t != "" {
				turn.Blocks = append(turn.Blocks, llm.Block{Kind: llm.BlockText, Text: t})
			}
		case "thinking":
			turn.Blocks = append(turn.Blocks, llm.Block{Kind: llm.BlockThinking, Text: b.Thinking, Signature: b.Signature})
		case "tool_use":
			if turn.StopReason == llm.StopMaxTokens {
				continue // the arguments may be cut off, and the SDK would show them as {}
			}
			input := json.RawMessage(b.Input)
			if len(input) == 0 {
				input = json.RawMessage("{}")
			}
			if !json.Valid(input) {
				return llm.ChatTurn{}, fmt.Errorf("anthropic: tool call %q has invalid arguments", b.Name)
			}
			turn.Blocks = append(turn.Blocks, llm.Block{Kind: llm.BlockToolUse, ToolUseID: b.ID, ToolName: b.Name, ToolInput: input})
		}
	}
	return turn, nil
}
