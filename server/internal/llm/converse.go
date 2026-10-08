package llm

import (
	"context"
	"encoding/json"
	"strings"
)

// Converser runs one turn of a tool-using conversation: it is given the history and the tools the
// model may call, streams the text as it is written, and returns the model's complete answer for
// the turn. The caller owns the loop (run the tools, append the results, call again).
type Converser interface {
	Converse(ctx context.Context, req ChatRequest, emit func(StreamEvent)) (ChatTurn, Usage, error)
	Name() string
	Model() string
}

type ChatRequest struct {
	// System is the instruction text, stable parts first. Providers cache by prefix, so anything
	// that changes per request goes last.
	System    []string
	Messages  []Message
	Tools     []ToolSpec
	MaxTokens int
}

// ToolSpec declares a tool the model may call. Schema is the JSON Schema of its input object.
type ToolSpec struct {
	Name        string
	Description string
	Schema      map[string]any
}

type BlockKind string

const (
	BlockText       BlockKind = "text"
	BlockThinking   BlockKind = "thinking"
	BlockToolUse    BlockKind = "tool_use"
	BlockToolResult BlockKind = "tool_result"
)

// Block is one piece of a message. Only the fields of its Kind are used.
type Block struct {
	Kind BlockKind
	// Text is the text (BlockText), the reasoning (BlockThinking) or the tool output (BlockToolResult).
	Text string
	// Signature belongs to BlockThinking. It must be sent back unchanged with the block.
	Signature string
	// ToolUseID links a BlockToolUse to the BlockToolResult that answers it.
	ToolUseID string
	ToolName  string
	ToolInput json.RawMessage
	IsError   bool
}

type Message struct {
	Role   string // "user" or "assistant"
	Blocks []Block
}

// StreamEvent is something worth showing while the turn is still being written. Only text is
// streamed; tool calls arrive complete in the ChatTurn.
type StreamEvent struct{ TextDelta string }

// ChatTurn is the model's complete answer for one turn. Blocks must be appended to the history
// as they are, thinking blocks included, or the next request is refused by the endpoint.
type ChatTurn struct {
	Blocks     []Block
	StopReason string // end_turn | tool_use | max_tokens | refusal
}

const (
	StopEndTurn   = "end_turn"
	StopToolUse   = "tool_use"
	StopMaxTokens = "max_tokens"
	StopRefusal   = "refusal"
)

// ToolCalls returns the tool_use blocks of the turn, in order.
func (t ChatTurn) ToolCalls() []Block {
	var calls []Block
	for _, b := range t.Blocks {
		if b.Kind == BlockToolUse {
			calls = append(calls, b)
		}
	}
	return calls
}

// Text returns the turn's visible text.
func (t ChatTurn) Text() string {
	var sb strings.Builder
	for _, b := range t.Blocks {
		if b.Kind == BlockText {
			sb.WriteString(b.Text)
		}
	}
	return sb.String()
}

type refKey struct{}

type ref struct{ refID, deviceID string }

// WithRef tags the context so call logs can be tied to what the call was for (a conversation id)
// and who asked (a device id).
func WithRef(ctx context.Context, refID, deviceID string) context.Context {
	return context.WithValue(ctx, refKey{}, ref{refID, deviceID})
}

func refFrom(ctx context.Context) ref {
	r, _ := ctx.Value(refKey{}).(ref)
	return r
}

// NoiseFilter removes internal markers that some gateways leak into the reply text, such as
// DeepSeek's <ds_safety>…</ds_safety> (plus the word "Safe" it leaves right after the closing tag).
// Text arrives in arbitrary pieces, so a marker can be split across calls; the filter holds back
// anything that might be the start of one. Use a new filter per text block.
type NoiseFilter struct {
	pending string
	closing string // the closing tag being waited for; empty when outside a marker
	trail   bool   // just left a marker; an immediately following "Safe" is part of it
	dropped bool   // a marker has been removed from this text
}

const noiseOpen = "<ds_"
const noiseTrail = "Safe"

// maxNoise caps how much text is held while waiting for a closing tag; a marker this long is not
// one, so it is let through rather than swallowing the reply.
const maxNoise = 4096

// Write takes the next piece of text and returns what can be shown now.
func (f *NoiseFilter) Write(s string) string {
	f.pending += s
	var out strings.Builder
	for {
		if f.closing != "" {
			i := strings.Index(f.pending, f.closing)
			if i < 0 {
				if len(f.pending) > maxNoise {
					out.WriteString(f.pending)
					f.pending, f.closing = "", ""
				}
				return out.String()
			}
			f.pending = f.pending[i+len(f.closing):]
			f.closing, f.trail, f.dropped = "", true, true
			continue
		}
		if f.trail {
			if len(f.pending) < len(noiseTrail) && strings.HasPrefix(noiseTrail, f.pending) {
				return out.String() // might still become "Safe"
			}
			f.pending = strings.TrimPrefix(f.pending, noiseTrail)
			f.trail = false
		}
		i := strings.Index(f.pending, noiseOpen)
		if i < 0 {
			// Hold back a tail that could still grow into the opening "<ds_".
			keep := 0
			for n := min(len(noiseOpen)-1, len(f.pending)); n > 0; n-- {
				if strings.HasSuffix(f.pending, noiseOpen[:n]) {
					keep = n
					break
				}
			}
			out.WriteString(f.pending[:len(f.pending)-keep])
			f.pending = f.pending[len(f.pending)-keep:]
			return out.String()
		}
		out.WriteString(f.pending[:i])
		f.pending = f.pending[i:]
		end := strings.IndexByte(f.pending, '>')
		if end < 0 {
			if len(f.pending) > 64 {
				out.WriteString(f.pending[:1]) // not a tag after all
				f.pending = f.pending[1:]
				continue
			}
			return out.String() // the tag name is still arriving
		}
		name := f.pending[1:end]
		if !isNoiseName(name) {
			out.WriteString(f.pending[:1])
			f.pending = f.pending[1:]
			continue
		}
		f.closing = "</" + name + ">"
		f.pending = f.pending[end+1:]
	}
}

// Flush returns what was held back once the text has ended. A marker that never closed is dropped.
// The filter can be reused for the next text afterwards (Dropped keeps reporting until then).
func (f *NoiseFilter) Flush() string {
	rest := f.pending
	closed := f.closing == ""
	dropped := f.dropped || !closed
	*f = NoiseFilter{dropped: dropped}
	if !closed {
		return ""
	}
	return rest
}

// Dropped reports whether any marker was removed from the text written so far.
func (f *NoiseFilter) Dropped() bool { return f.dropped || f.closing != "" }

func isNoiseName(name string) bool {
	if !strings.HasPrefix(name, "ds_") || len(name) == len("ds_") || len(name) > 32 {
		return false
	}
	for _, r := range name {
		if !(r == '_' || r >= 'a' && r <= 'z' || r >= '0' && r <= '9') {
			return false
		}
	}
	return true
}

// StripNoise filters a complete text in one go.
func StripNoise(s string) string {
	var f NoiseFilter
	return f.Write(s) + f.Flush()
}
