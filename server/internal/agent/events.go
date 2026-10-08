// Package agent runs the study assistant: a model that can look things up in the lesson library
// (and, in question-writing mode, propose draft questions) while it answers. It depends on the llm
// package and a narrow Library interface, not on the database.
package agent

// Event is something the assistant tells the client while it works. The HTTP layer sends each as
// one SSE event named by EventName.
type Event interface{ EventName() string }

type Start struct {
	ConversationID string `json:"conversation_id"`
}

type Delta struct {
	Text string `json:"text"`
}

// ToolEvent reports a tool call's progress. Label is a ready-to-show line, so clients do not need
// to know the tool names.
type ToolEvent struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Label  string `json:"label"`
	Status string `json:"status"` // running | done | error
}

type Usage struct {
	Input  int64 `json:"input"`
	Output int64 `json:"output"`
	Cached int64 `json:"cached"`
}

type Done struct {
	Stop  string `json:"stop"` // end_turn | max_rounds | max_tokens
	Usage Usage  `json:"usage"`
}

type Error struct {
	Code    string `json:"code"` // budget_exceeded | unavailable | refused | timeout | internal
	Message string `json:"message"`
}

func (Start) EventName() string     { return "start" }
func (Delta) EventName() string     { return "delta" }
func (ToolEvent) EventName() string { return "tool" }
func (Done) EventName() string      { return "done" }
func (Error) EventName() string     { return "error" }
