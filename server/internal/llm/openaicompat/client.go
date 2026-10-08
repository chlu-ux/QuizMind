package openaicompat

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"time"

	"github.com/chlu-ux/quizmind/server/internal/llm"
)

// Options configures a Client. BaseURL includes the version segment, e.g. https://api.openai.com/v1.
type Options struct {
	APIKey      string
	BaseURL     string
	Model       string
	MaxTokens   int     // default output cap when a request does not set one
	Temperature float64 // sent only when above zero
	HTTP        *http.Client
}

// Client implements llm.Client for any OpenAI-compatible chat completions endpoint.
type Client struct {
	opts Options
	hc   *http.Client
	// mode is the structured-output mode that last worked, so a gateway without json_schema is only
	// tried (and refused) once.
	mode atomic.Int32
}

const (
	modeSchema int32 = iota // response_format json_schema
	modeObject              // response_format json_object, schema in the prompt
	modePlain               // schema in the prompt only
)

func New(o Options) (*Client, error) {
	switch {
	case o.APIKey == "":
		return nil, fmt.Errorf("openai: api key is empty")
	case o.BaseURL == "":
		return nil, fmt.Errorf("openai: base url is empty")
	case o.Model == "":
		return nil, fmt.Errorf("openai: model is empty")
	}
	if o.MaxTokens <= 0 {
		o.MaxTokens = 8000
	}
	hc := o.HTTP
	if hc == nil {
		hc = &http.Client{Timeout: 5 * time.Minute}
	}
	return &Client{opts: o, hc: hc}, nil
}

func (c *Client) Name() string  { return "openai" }
func (c *Client) Model() string { return c.opts.Model }

// Ping makes a tiny plain-text request.
func (c *Client) Ping(ctx context.Context) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	return Chat(ctx, c.hc, c.opts.BaseURL, c.opts.APIKey, c.opts.Model, "Reply with the single word: pong", 32)
}

type apiError struct {
	status int
	body   string
}

func (e *apiError) Error() string { return fmt.Sprintf("endpoint returned %d: %s", e.status, e.body) }

// GenerateJSON asks for schema-conforming output. Endpoints differ in what they support, so it tries
// json_schema first, then json_object, then a plain prompt, and remembers the first that is accepted.
func (c *Client) GenerateJSON(ctx context.Context, req llm.JSONRequest, out any) (llm.Usage, error) {
	var usage llm.Usage
	for mode := c.mode.Load(); mode <= modePlain; mode++ {
		u, text, err := c.complete(ctx, req, mode)
		usage.InputTokens += u.InputTokens
		usage.OutputTokens += u.OutputTokens
		usage.CachedTokens += u.CachedTokens
		if err != nil {
			var ae *apiError
			// A 400 / 422 means "not supported here"; try the next, looser mode. Anything else is final.
			if asAPIError(err, &ae) && (ae.status == 400 || ae.status == 422) && mode < modePlain {
				continue
			}
			return usage, err
		}
		c.mode.Store(mode)
		raw, err := llm.ExtractJSON(text)
		if err != nil {
			return usage, fmt.Errorf("openai: %w", err)
		}
		if err := json.Unmarshal(raw, out); err != nil {
			return usage, fmt.Errorf("openai: decode output: %w", err)
		}
		return usage, nil
	}
	return usage, fmt.Errorf("openai: no structured-output mode was accepted")
}

func asAPIError(err error, target **apiError) bool {
	ae, ok := err.(*apiError)
	if ok {
		*target = ae
	}
	return ok
}

func (c *Client) complete(ctx context.Context, req llm.JSONRequest, mode int32) (llm.Usage, string, error) {
	maxTokens := req.MaxTokens
	if maxTokens <= 0 {
		maxTokens = c.opts.MaxTokens
	}
	system := req.System
	body := map[string]any{"model": c.opts.Model, "max_tokens": maxTokens}
	if c.opts.Temperature > 0 {
		body["temperature"] = c.opts.Temperature
	}
	switch mode {
	case modeSchema:
		name := req.SchemaName
		if name == "" {
			name = "output"
		}
		body["response_format"] = map[string]any{
			"type":        "json_schema",
			"json_schema": map[string]any{"name": name, "strict": true, "schema": req.Schema},
		}
	case modeObject:
		body["response_format"] = map[string]any{"type": "json_object"}
		system = llm.PromptForJSON(system, req.Schema)
	default:
		system = llm.PromptForJSON(system, req.Schema)
	}
	body["messages"] = []map[string]string{{"role": "system", "content": system}, {"role": "user", "content": req.User}}

	raw, err := c.post(ctx, body)
	if err != nil {
		return llm.Usage{}, "", err
	}
	var resp struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
				Refusal string `json:"refusal"`
			} `json:"message"`
			FinishReason string `json:"finish_reason"`
		} `json:"choices"`
		Usage struct {
			PromptTokens        int64 `json:"prompt_tokens"`
			CompletionTokens    int64 `json:"completion_tokens"`
			PromptTokensDetails struct {
				CachedTokens int64 `json:"cached_tokens"`
			} `json:"prompt_tokens_details"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil || len(resp.Choices) == 0 {
		return llm.Usage{}, "", fmt.Errorf("unexpected response: %s", snippet(raw))
	}
	cached := resp.Usage.PromptTokensDetails.CachedTokens
	usage := llm.Usage{
		InputTokens:  resp.Usage.PromptTokens - cached,
		OutputTokens: resp.Usage.CompletionTokens,
		CachedTokens: cached,
	}
	ch := resp.Choices[0]
	switch {
	case ch.Message.Refusal != "":
		return usage, "", fmt.Errorf("%w: %s", llm.ErrRefused, ch.Message.Refusal)
	case ch.FinishReason == "length":
		return usage, "", llm.ErrTruncated
	case ch.FinishReason == "content_filter":
		return usage, "", fmt.Errorf("%w: content filter", llm.ErrRefused)
	case strings.TrimSpace(ch.Message.Content) == "":
		return usage, "", fmt.Errorf("openai: the reply is empty (finish_reason=%s)", ch.FinishReason)
	}
	return usage, ch.Message.Content, nil
}

func (c *Client) post(ctx context.Context, body map[string]any) ([]byte, error) {
	payload, _ := json.Marshal(body)
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost,
		strings.TrimRight(c.opts.BaseURL, "/")+"/chat/completions", bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Authorization", "Bearer "+c.opts.APIKey)
	resp, err := c.hc.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("cannot reach %s: %w", c.opts.BaseURL, err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if resp.StatusCode/100 != 2 {
		return nil, &apiError{status: resp.StatusCode, body: snippet(raw)}
	}
	return raw, nil
}
