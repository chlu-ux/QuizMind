// Package fake provides a scriptable llm.Client for tests and offline demos.
package fake

import (
	"context"
	"encoding/json"
	"sync"

	"github.com/chlu-ux/quizmind/server/internal/llm"
)

// Handler produces the JSON value for a request.
type Handler func(req llm.JSONRequest) (any, error)

type Client struct {
	mu      sync.Mutex
	handler Handler
	calls   []llm.JSONRequest
}

func New(h Handler) *Client { return &Client{handler: h} }

func (c *Client) Name() string  { return "fake" }
func (c *Client) Model() string { return "fake-model" }

func (c *Client) Calls() []llm.JSONRequest {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]llm.JSONRequest(nil), c.calls...)
}

func (c *Client) GenerateJSON(_ context.Context, req llm.JSONRequest, out any) (llm.Usage, error) {
	c.mu.Lock()
	c.calls = append(c.calls, req)
	c.mu.Unlock()
	v, err := c.handler(req)
	if err != nil {
		return llm.Usage{}, err
	}
	raw, err := json.Marshal(v)
	if err != nil {
		return llm.Usage{}, err
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return llm.Usage{}, err
	}
	return llm.Usage{InputTokens: int64(len(req.User) / 4), OutputTokens: int64(len(raw) / 4)}, nil
}
