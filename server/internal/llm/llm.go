// Package llm defines a provider-neutral client interface for structured
// generation, plus a Guard that adds concurrency/rate/budget control and call
// logging on top of any provider.
package llm

import (
	"context"
	"errors"
)

// Role names a task the pipeline needs a model for. Each role is bound to a
// provider and model in configuration.
type Role string

const (
	RoleGenerator Role = "generator"
	RoleValidator Role = "validator"
	RoleEmbedding Role = "embedding"
	// RoleAgent is the study / question-writing assistant (Anthropic protocol only).
	RoleAgent Role = "agent"
	// RoleExplain is the AI explanation the apps call themselves; the server never calls it, but
	// the apps report its token usage under this name.
	RoleExplain Role = "explain"
)

// Protocol names the wire format a provider speaks.
type Protocol string

const (
	ProtocolAnthropic Protocol = "anthropic"
	ProtocolOpenAI    Protocol = "openai"
)

// Client is implemented once per provider protocol.
type Client interface {
	// GenerateJSON asks the model for output matching req.Schema and
	// unmarshals it into out. Implementations must not return partial output
	// as success: a truncated or unparsable response is an error.
	GenerateJSON(ctx context.Context, req JSONRequest, out any) (Usage, error)
	// Name identifies the provider type for logging, e.g. "anthropic".
	Name() string
	// Model is the model id this client calls.
	Model() string
}

type JSONRequest struct {
	// System is the stable instruction prefix. Keep it byte-identical across
	// calls so provider-side prompt caching can hit.
	System string
	// User carries the per-call variable content.
	User       string
	SchemaName string
	Schema     map[string]any
	MaxTokens  int
}

type Usage struct {
	InputTokens  int64
	OutputTokens int64
	CachedTokens int64
}

// Pinger is implemented by clients that can make a tiny plain-text request, so the admin UI can
// check that a saved provider and model work.
type Pinger interface {
	Ping(ctx context.Context) (string, error)
}

// ErrBudgetExceeded is returned by Guard when the daily token budget is spent.
// It is not retryable within the same day.
var ErrBudgetExceeded = errors.New("llm: daily token budget exceeded")

// ErrTruncated signals the model stopped because of the output token cap.
var ErrTruncated = errors.New("llm: response truncated (max_tokens reached)")

// ErrRefused signals the model declined the request.
var ErrRefused = errors.New("llm: model refused the request")

// Check is one line of a compatibility report.
type Check struct {
	Name   string `json:"name"`
	OK     bool   `json:"ok"`
	Detail string `json:"detail,omitempty"`
}

// Prober is implemented by clients that can check what an endpoint supports beyond a plain
// request, so the admin UI can say before anyone relies on it whether a model can drive the assistant.
type Prober interface {
	Probe(ctx context.Context) []Check
}
