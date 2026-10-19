package agent

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"

	"github.com/chlu-ux/quizmind/server/internal/llm"
)

// Spec is everything an app needs to run the assistant itself when the server cannot be reached:
// the instructions, the tools the model may call, and the limits the server applies. The apps keep
// no copy of the wording, so a change here reaches them with the next sync. Version changes whenever
// any of it does.
type Spec struct {
	Version string `json:"version"`
	// Prompt is the stable system text of the whole assistant (explains, quizzes, writes questions).
	Prompt string     `json:"prompt"`
	Tools  []SpecTool `json:"tools"`
	Limits SpecLimits `json:"limits"`
}

// SpecTool is one tool as the model is told about it.
type SpecTool struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"input_schema"`
}

// SpecLimits are the bounds the server puts on a conversation; an app keeps to the same ones.
type SpecLimits struct {
	MaxRounds         int `json:"max_rounds"`
	MaxProposePerCall int `json:"max_propose_per_call"`
	MaxDraftsPerChat  int `json:"max_drafts_per_chat"`
	MaxToolResult     int `json:"max_tool_result"`
	// WrapUpNudge is said to the model when its tool budget is spent.
	WrapUpNudge string `json:"wrap_up_nudge"`
}

// BuildSpec describes the assistant. The tools that need a file or a database are left out: an app
// has the library on the device, but not the files of a server-side conversation.
func BuildSpec() Spec {
	list := append(readTools(), toolProposeQuestions(nil, DraftScope{}), toolListDrafts(nil, DraftScope{}))
	s := Spec{
		Prompt: SystemPrompt(ModeCreate),
		Limits: SpecLimits{MaxRounds: DefaultMaxRounds, MaxProposePerCall: MaxProposePerCall,
			MaxDraftsPerChat: MaxDraftsPerChat, MaxToolResult: maxToolResult, WrapUpNudge: wrapUpNudge},
	}
	for _, t := range list {
		s.Tools = append(s.Tools, SpecTool{Name: t.spec.Name, Description: t.spec.Description, InputSchema: inputSchema(t.spec)})
	}
	raw, _ := json.Marshal(s)
	sum := sha256.Sum256(raw)
	s.Version = PromptVersion + "-" + hex.EncodeToString(sum[:6])
	return s
}

// inputSchema is the tool's schema with an empty "required" left out, which some endpoints refuse as null.
func inputSchema(spec llm.ToolSpec) map[string]any {
	out := map[string]any{}
	for k, v := range spec.Schema {
		if r, ok := v.([]string); ok && k == "required" && len(r) == 0 {
			continue
		}
		out[k] = v
	}
	return out
}
