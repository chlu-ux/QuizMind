// Package anthropic implements llm.Client on top of the official Anthropic Go SDK.
package anthropic

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

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
func (c *Client) GenerateJSON(ctx context.Context, req llm.JSONRequest, out any) (llm.Usage, error) {
	maxTokens := req.MaxTokens
	if maxTokens <= 0 {
		maxTokens = c.opts.MaxTokens
	}
	params := sdk.MessageNewParams{
		Model:     sdk.Model(c.opts.Model),
		MaxTokens: int64(maxTokens),
		System: []sdk.TextBlockParam{{
			Text:         req.System,
			CacheControl: sdk.NewCacheControlEphemeralParam(),
		}},
		Messages: []sdk.MessageParam{
			sdk.NewUserMessage(sdk.NewTextBlock(req.User)),
		},
		OutputConfig: sdk.OutputConfigParam{
			Format: sdk.JSONOutputFormatParam{Schema: req.Schema},
		},
	}
	if c.opts.Effort != "" {
		params.OutputConfig.Effort = sdk.OutputConfigEffort(c.opts.Effort)
	}

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

	var text strings.Builder
	for _, block := range resp.Content {
		if tb, ok := block.AsAny().(sdk.TextBlock); ok {
			text.WriteString(tb.Text)
		}
	}
	if text.Len() == 0 {
		return usage, fmt.Errorf("anthropic: response contained no text block (stop_reason=%s)", resp.StopReason)
	}
	if err := json.Unmarshal([]byte(text.String()), out); err != nil {
		return usage, fmt.Errorf("anthropic: decode structured output: %w", err)
	}
	return usage, nil
}
