package fake

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"

	"github.com/chlu-ux/quizmind/server/internal/llm"
)

// Call is a tool call a scripted turn makes.
type Call struct {
	Name  string
	Input string // JSON object
}

// Turn is one scripted model answer.
type Turn struct {
	Text  string
	Calls []Call
	Err   error
	Usage llm.Usage
	// Stop overrides the stop reason; by default it is tool_use when there are calls, else end_turn.
	Stop string
}

// Converser is a scripted llm.Converser. It streams each turn's text in small pieces, so code that
// handles split text gets exercised.
type Converser struct {
	mu    sync.Mutex
	next  func(n int, req llm.ChatRequest) Turn
	reqs  []llm.ChatRequest
	delay func(context.Context) error
}

// NewConverser answers with fn(n, req), n counting model calls from 0.
func NewConverser(fn func(n int, req llm.ChatRequest) Turn) *Converser { return &Converser{next: fn} }

// Script answers with the given turns in order; asking for more is an error.
func Script(turns ...Turn) *Converser {
	return NewConverser(func(n int, _ llm.ChatRequest) Turn {
		if n >= len(turns) {
			return Turn{Err: fmt.Errorf("fake: script has no turn %d", n)}
		}
		return turns[n]
	})
}

// Block makes every call wait for ctx or for the returned release function.
func (c *Converser) Block() (release func()) {
	ch := make(chan struct{})
	c.delay = func(ctx context.Context) error {
		select {
		case <-ch:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return func() { close(ch) }
}

func (c *Converser) Name() string  { return "fake" }
func (c *Converser) Model() string { return "fake-model" }

// Requests returns what the model was asked, call by call.
func (c *Converser) Requests() []llm.ChatRequest {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]llm.ChatRequest(nil), c.reqs...)
}

func (c *Converser) Converse(ctx context.Context, req llm.ChatRequest, emit func(llm.StreamEvent)) (llm.ChatTurn, llm.Usage, error) {
	c.mu.Lock()
	n := len(c.reqs)
	// Keep a copy: the caller goes on appending to its history.
	req.Messages = append([]llm.Message(nil), req.Messages...)
	c.reqs = append(c.reqs, req)
	c.mu.Unlock()

	if c.delay != nil {
		if err := c.delay(ctx); err != nil {
			return llm.ChatTurn{}, llm.Usage{}, err
		}
	}
	t := c.next(n, req)
	if t.Err != nil {
		return llm.ChatTurn{}, t.Usage, t.Err
	}
	turn := llm.ChatTurn{StopReason: llm.StopEndTurn}
	if t.Text != "" {
		runes := []rune(t.Text)
		for i := 0; i < len(runes); i += 3 {
			if emit != nil {
				emit(llm.StreamEvent{TextDelta: string(runes[i:min(i+3, len(runes))])})
			}
		}
		turn.Blocks = append(turn.Blocks, llm.Block{Kind: llm.BlockText, Text: t.Text})
	}
	for i, call := range t.Calls {
		turn.StopReason = llm.StopToolUse
		turn.Blocks = append(turn.Blocks, llm.Block{Kind: llm.BlockToolUse, ToolUseID: fmt.Sprintf("call_%d_%d", n, i),
			ToolName: call.Name, ToolInput: json.RawMessage(call.Input)})
	}
	if t.Stop != "" {
		turn.StopReason = t.Stop
	}
	return turn, t.Usage, nil
}
