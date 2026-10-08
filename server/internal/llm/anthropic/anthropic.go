// Package anthropic implements llm.Client on top of the official Anthropic Go SDK.
package anthropic

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync/atomic"
	"time"

	sdk "github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/option"

	"github.com/chlu-ux/quizmind/server/internal/llm"
)

type Options struct {
	APIKey  string
	BaseURL string // optional, for proxies
	Model   string
	// Effort is low|medium|high|xhigh|max. Empty uses the model default.
	Effort string
	// MaxTokens is the default output cap when a request does not set one.
	MaxTokens int
}

type Client struct {
	c    sdk.Client
	opts Options
	// promptMode is set once the endpoint has shown it cannot do structured outputs.
	promptMode atomic.Bool
}

func New(o Options) (*Client, error) {
	if o.APIKey == "" {
		return nil, fmt.Errorf("anthropic: api key is empty")
	}
	if o.Model == "" {
		return nil, fmt.Errorf("anthropic: model is empty")
	}
	if o.MaxTokens <= 0 {
		o.MaxTokens = 16000
	}
	ro := []option.RequestOption{option.WithAPIKey(o.APIKey)}
	if o.BaseURL != "" {
		ro = append(ro, option.WithBaseURL(o.BaseURL))
	}
	return &Client{c: sdk.NewClient(ro...), opts: o}, nil
}

func (c *Client) Name() string  { return "anthropic" }
func (c *Client) Model() string { return c.opts.Model }

// GenerateJSON uses structured outputs (output_config.format) rather than
// forced tool use: Sonnet 5.5 rejects tool_choice any/tool, and structured
// outputs guarantee schema-valid JSON in the text block. Sampling parameters
// are deliberately not sent, since this model family rejects non-default values.
//
// Gateways that speak the Anthropic protocol often lack structured outputs. When the endpoint
// refuses the request as malformed, it is asked once more with the schema in the prompt and the
// reply parsed as text; if that works, that mode is used from then on.
func (c *Client) GenerateJSON(ctx context.Context, req llm.JSONRequest, out any) (llm.Usage, error) {
	if !c.promptMode.Load() {
		usage, err := c.generate(ctx, req, out, false)
		if !isUnsupported(err) {
			return usage, err
		}
		usage2, err2 := c.generate(ctx, req, out, true)
		if err2 == nil {
			c.promptMode.Store(true)
		}
		return usage2, err2
	}
	return c.generate(ctx, req, out, true)
}

// isUnsupported reports an API refusal that "this request shape is not supported here".
func isUnsupported(err error) bool {
	var ae *sdk.Error
	if !errors.As(err, &ae) {
		return false
	}
	switch ae.StatusCode {
	case http.StatusBadRequest, http.StatusNotFound, http.StatusUnprocessableEntity:
		return true
	}
	return false
}

func (c *Client) generate(ctx context.Context, req llm.JSONRequest, out any, prompt bool) (llm.Usage, error) {
	maxTokens := req.MaxTokens
	if maxTokens <= 0 {
		maxTokens = c.opts.MaxTokens
	}
	system := req.System
	params := sdk.MessageNewParams{
		Model:     sdk.Model(c.opts.Model),
		MaxTokens: int64(maxTokens),
		Messages: []sdk.MessageParam{
			sdk.NewUserMessage(sdk.NewTextBlock(req.User)),
		},
	}
	if prompt {
		system = llm.PromptForJSON(system, req.Schema)
	} else {
		params.OutputConfig = sdk.OutputConfigParam{Format: sdk.JSONOutputFormatParam{Schema: req.Schema}}
		if c.opts.Effort != "" {
			params.OutputConfig.Effort = sdk.OutputConfigEffort(c.opts.Effort)
		}
	}
	params.System = []sdk.TextBlockParam{{Text: system, CacheControl: sdk.NewCacheControlEphemeralParam()}}

	resp, err := c.c.Messages.New(ctx, params)
	if err != nil {
		return llm.Usage{}, fmt.Errorf("anthropic messages: %w", err)
	}
	usage := llm.Usage{
		InputTokens:  resp.Usage.InputTokens + resp.Usage.CacheCreationInputTokens,
		OutputTokens: resp.Usage.OutputTokens,
		CachedTokens: resp.Usage.CacheReadInputTokens,
	}

	switch resp.StopReason {
	case sdk.StopReasonRefusal:
		return usage, fmt.Errorf("%w: category=%q", llm.ErrRefused, resp.StopDetails.Category)
	case sdk.StopReasonMaxTokens:
		return usage, llm.ErrTruncated
	}

	text := responseText(resp)
	if text == "" {
		return usage, fmt.Errorf("anthropic: response contained no text block (stop_reason=%s)", resp.StopReason)
	}
	if prompt {
		raw, err := llm.ExtractJSON(text)
		if err != nil {
			return usage, fmt.Errorf("anthropic: %w", err)
		}
		text = string(raw)
	}
	if err := json.Unmarshal([]byte(text), out); err != nil {
		return usage, fmt.Errorf("anthropic: decode structured output: %w", err)
	}
	return usage, nil
}

func responseText(resp *sdk.Message) string {
	var text strings.Builder
	for _, block := range resp.Content {
		if tb, ok := block.AsAny().(sdk.TextBlock); ok {
			text.WriteString(tb.Text)
		}
	}
	return text.String()
}

// Ping makes a tiny plain-text request, to check that the key, address and model work.
func (c *Client) Ping(ctx context.Context) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	resp, err := c.c.Messages.New(ctx, sdk.MessageNewParams{
		Model:     sdk.Model(c.opts.Model),
		MaxTokens: 32,
		Messages:  []sdk.MessageParam{sdk.NewUserMessage(sdk.NewTextBlock("Reply with the single word: pong"))},
	})
	if err != nil {
		return "", fmt.Errorf("anthropic messages: %w", err)
	}
	return responseText(resp), nil
}
