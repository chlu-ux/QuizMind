package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"unicode/utf8"

	"github.com/chlu-ux/quizmind/server/internal/llm"
)

// maxToolResult caps what one tool result sends back to the model.
const maxToolResult = 6000

// env is what a conversation's tools share.
type env struct {
	lib  *snapshot
	bank string // the bank the learner is in; the default for tools that take bank_id

	mu     sync.Mutex
	seen   map[string]bool // ids the model has been shown, which links may point to
	drafts []Draft         // drafts made since the last takeDrafts
}

func newEnv(lib Library, bankID string) *env {
	return &env{lib: newSnapshot(lib), bank: bankID, seen: map[string]bool{}}
}

func (e *env) see(ids ...string) {
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, id := range ids {
		if id != "" {
			e.seen[id] = true
		}
	}
}

func (e *env) known(id string) bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.seen[id]
}

func (e *env) addDrafts(d []Draft) {
	if len(d) == 0 {
		return
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	e.drafts = append(e.drafts, d...)
}

// takeDrafts returns the drafts made since the last call.
func (e *env) takeDrafts() []Draft {
	e.mu.Lock()
	defer e.mu.Unlock()
	d := e.drafts
	e.drafts = nil
	return d
}

// bankOrDefault resolves a tool's bank_id argument.
func (e *env) bankOrDefault(arg string) string {
	if arg != "" {
		return arg
	}
	return e.bank
}

// errBadArgs marks a mistake in the model's arguments; the message goes back to the model so it can fix the call.
var errBadArgs = errors.New("bad arguments")

func badArgs(format string, a ...any) error {
	return fmt.Errorf("%w: %s", errBadArgs, fmt.Sprintf(format, a...))
}

type tool struct {
	spec  llm.ToolSpec
	label func(ctx context.Context, e *env, args json.RawMessage) string
	run   func(ctx context.Context, e *env, args json.RawMessage) (any, error)
}

// toolSet is the tools a conversation may use, by name.
type toolSet struct {
	order []string
	by    map[string]*tool
}

func newToolSet(tools ...*tool) *toolSet {
	ts := &toolSet{by: map[string]*tool{}}
	for _, t := range tools {
		ts.order = append(ts.order, t.spec.Name)
		ts.by[t.spec.Name] = t
	}
	return ts
}

func (ts *toolSet) specs() []llm.ToolSpec {
	out := make([]llm.ToolSpec, 0, len(ts.order))
	for _, n := range ts.order {
		out = append(out, ts.by[n].spec)
	}
	return out
}

// execute runs one tool call and returns the text for the tool_result and whether it failed.
func (ts *toolSet) execute(ctx context.Context, e *env, name string, args json.RawMessage) (string, bool) {
	t, ok := ts.by[name]
	if !ok {
		return fmt.Sprintf("没有名为 %q 的工具。可用的工具：%s", name, strings.Join(ts.order, "、")), true
	}
	res, err := t.run(ctx, e, args)
	if err != nil {
		if errors.Is(err, errBadArgs) {
			return strings.TrimPrefix(err.Error(), errBadArgs.Error()+": "), true
		}
		return "工具执行失败，请换个办法或如实告诉用户。", true
	}
	return limitResult(res), false
}

func (ts *toolSet) labelFor(ctx context.Context, e *env, name string, args json.RawMessage) string {
	if t, ok := ts.by[name]; ok && t.label != nil {
		return t.label(ctx, e, args)
	}
	return name
}

func limitResult(res any) string {
	var s string
	switch v := res.(type) {
	case string:
		s = v
	default:
		var sb strings.Builder
		enc := json.NewEncoder(&sb)
		enc.SetEscapeHTML(false) // keep "考点精讲 > 2.1" readable and short
		_ = enc.Encode(v)
		s = strings.TrimSuffix(sb.String(), "\n")
	}
	if utf8.RuneCountInString(s) <= maxToolResult {
		return s
	}
	return string([]rune(s)[:maxToolResult]) + "…（已截断，请缩小范围）"
}

// parseArgs decodes tool arguments, treating an empty body as {}.
func parseArgs(raw json.RawMessage, into any) error {
	if len(strings.TrimSpace(string(raw))) == 0 {
		raw = json.RawMessage("{}")
	}
	if err := json.Unmarshal(raw, into); err != nil {
		return badArgs("参数不是合法的 JSON 对象：%v", err)
	}
	return nil
}

func clampLimit(n, def, max int) int {
	switch {
	case n <= 0:
		return def
	case n > max:
		return max
	}
	return n
}

// lessonTitle is the last part of a heading path ("考点精讲 > 2.1 操作系统概述" gives "2.1 操作系统概述").
func lessonTitle(l *Lesson) string {
	parts := strings.Split(l.HeadingPath, " > ")
	if last := strings.TrimSpace(parts[len(parts)-1]); last != "" {
		return last
	}
	return l.HeadingPath
}

// schema builds an object schema from property definitions.
func schema(required []string, props map[string]any) map[string]any {
	return map[string]any{"type": "object", "properties": props, "required": required}
}

func str(desc string) map[string]any { return map[string]any{"type": "string", "description": desc} }
func integer(desc string) map[string]any {
	return map[string]any{"type": "integer", "description": desc}
}
func boolean(desc string) map[string]any {
	return map[string]any{"type": "boolean", "description": desc}
}

func llmSpec(name, desc string, schema map[string]any) llm.ToolSpec {
	return llm.ToolSpec{Name: name, Description: desc, Schema: schema}
}
