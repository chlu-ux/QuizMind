package agent

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/chlu-ux/quizmind/server/internal/llm"
)

// Limits of one conversation request.
const (
	DefaultMaxRounds   = 8
	defaultToolTimeout = 15 * time.Second
	// wrapUpNudge is said when the tool budget is spent and the model must answer.
	wrapUpNudge = "已经查阅了足够多的资料。请不要再调用工具，直接基于已有的信息回答。"
)

// Agent runs conversations against one model.
type Agent struct {
	Conv llm.Converser
	Lib  Library
	// Drafter stores the questions the model proposes. Required for ModeCreate, unused otherwise.
	Drafter Drafter
	// MaxRounds bounds the model calls of one request; zero means DefaultMaxRounds.
	MaxRounds int
	// ToolTimeout bounds one tool call; zero means 15 seconds.
	ToolTimeout time.Duration
	// Now returns the current time, for the prompt; nil means time.Now.
	Now func() time.Time
}

// Modes of a conversation, fixed when it starts.
const (
	ModeLearn  = "learn"
	ModeCreate = "create"
)

// Request is one chat request after validation.
type Request struct {
	ConversationID string
	// Mode is ModeLearn (the default) or ModeCreate, which adds the tools that write draft questions.
	Mode     string
	DeviceID string
	// Messages is the text history; the last one is from the user.
	Messages []llm.Message
	Context  Context
	// MaxTokens caps one model turn; zero uses the model's setting.
	MaxTokens int
}

// Run answers the request, reporting progress through emit, and ends with exactly one Done or
// Error event (none when ctx was cancelled because the client went away). emit may be called from
// the goroutine running Run only.
func (a *Agent) Run(ctx context.Context, req Request, emit func(Event)) {
	maxRounds := a.MaxRounds
	if maxRounds <= 0 {
		maxRounds = DefaultMaxRounds
	}
	now := time.Now
	if a.Now != nil {
		now = a.Now
	}
	toolTimeout := a.ToolTimeout
	if toolTimeout <= 0 {
		toolTimeout = defaultToolTimeout
	}

	emit(Start{ConversationID: req.ConversationID})

	e := newEnv(a.Lib, req.Context.BankID)
	extra, err := a.contextText(ctx, e, req.Context)
	if err != nil {
		emit(Error{Code: "internal", Message: "读取资料失败，请稍后再试。"})
		return
	}
	list := []*tool{toolListOutline(), toolSearchLessons(), toolGetLesson(),
		toolSearchQuestions(), toolPickQuestions(), toolGetWeakPoints()}
	if req.Mode == ModeCreate {
		scope := DraftScope{ConversationID: req.ConversationID, DeviceID: req.DeviceID}
		list = append(list, toolProposeQuestions(a.Drafter, scope), toolListDrafts(a.Drafter, scope))
	}
	tools := newToolSet(list...)
	system := systemPrompts(now(), req.Mode, extra)
	history := append([]llm.Message(nil), req.Messages...)

	var usage Usage
	finish := func(stop string) { emit(Done{Stop: stop, Usage: usage}) }
	// Cancelled (not timed out): the client went away and nobody is listening.
	gone := func() bool { return errors.Is(ctx.Err(), context.Canceled) }

	// turn runs one model call. Text is checked for invented links before it is sent on.
	turn := func(tools []llm.ToolSpec) (llm.ChatTurn, error) {
		lf := &linkFilter{known: e.known}
		say := func(s string) {
			if s != "" {
				emit(Delta{Text: s})
			}
		}
		t, u, err := a.Conv.Converse(ctx, llm.ChatRequest{System: system, Messages: history, Tools: tools, MaxTokens: req.MaxTokens},
			func(ev llm.StreamEvent) { say(lf.Write(ev.TextDelta)) })
		say(lf.Flush())
		usage.Input += u.InputTokens
		usage.Output += u.OutputTokens
		usage.Cached += u.CachedTokens
		return t, err
	}
	fail := func(err error) {
		if gone() {
			return
		}
		emit(errorEvent(err))
	}

	for round := 1; round <= maxRounds; round++ {
		t, err := turn(tools.specs())
		if errors.Is(err, llm.ErrTruncated) {
			finish("max_tokens")
			return
		}
		if err != nil {
			fail(err)
			return
		}
		calls := t.ToolCalls()
		if t.StopReason != llm.StopToolUse || len(calls) == 0 {
			finish("end_turn")
			return
		}
		history = append(history, llm.Message{Role: "assistant", Blocks: t.Blocks})
		history = append(history, llm.Message{Role: "user", Blocks: a.runTools(ctx, e, tools, calls, toolTimeout, emit)})
		if ctx.Err() != nil {
			fail(ctx.Err())
			return
		}
	}

	// Out of rounds: one last turn without tools, so the user still gets an answer.
	last := &history[len(history)-1] // the tool results, which the nudge joins
	last.Blocks = append(last.Blocks, llm.Block{Kind: llm.BlockText, Text: wrapUpNudge})
	if _, err := turn(nil); err != nil && !errors.Is(err, llm.ErrTruncated) {
		fail(err)
		return
	}
	finish("max_rounds")
}

// runTools runs the calls of one turn in parallel and returns their tool_result blocks in order.
// Tool events are emitted from this goroutine only.
func (a *Agent) runTools(ctx context.Context, e *env, tools *toolSet, calls []llm.Block, timeout time.Duration, emit func(Event)) []llm.Block {
	results := make([]llm.Block, len(calls))
	labels := make([]string, len(calls))
	for i, c := range calls {
		labels[i] = tools.labelFor(ctx, e, c.ToolName, c.ToolInput)
		emit(ToolEvent{ID: c.ToolUseID, Name: c.ToolName, Label: labels[i], Status: "running"})
	}
	var wg sync.WaitGroup
	for i, c := range calls {
		wg.Add(1)
		go func() {
			defer wg.Done()
			tctx, cancel := context.WithTimeout(ctx, timeout)
			defer cancel()
			text, isErr := tools.execute(tctx, e, c.ToolName, c.ToolInput)
			if tctx.Err() != nil && ctx.Err() == nil {
				text, isErr = "工具执行超时，请缩小范围或换个办法。", true
			}
			results[i] = llm.Block{Kind: llm.BlockToolResult, ToolUseID: c.ToolUseID, Text: text, IsError: isErr}
		}()
	}
	wg.Wait()
	for i, c := range calls {
		status := "done"
		if results[i].IsError {
			status = "error"
		}
		emit(ToolEvent{ID: c.ToolUseID, Name: c.ToolName, Label: labels[i], Status: status})
	}
	if drafts := e.takeDrafts(); len(drafts) > 0 {
		emit(Drafts{Drafts: drafts})
	}
	return results
}

// contextText turns the request's context into text for the instructions and marks the ids in it as known.
func (a *Agent) contextText(ctx context.Context, e *env, c Context) (string, error) {
	var sb strings.Builder
	if c.LessonID != "" {
		l, err := e.lib.Lesson(ctx, c.LessonID)
		if err != nil {
			return "", err
		}
		if l != nil {
			e.see(l.ID)
			fmt.Fprintf(&sb, "用户正在阅读这一节讲义：\n<lesson id=%q path=%q>\n%s\n</lesson>\n", l.ID, l.HeadingPath, l.Text)
		}
	}
	if c.Question != nil {
		questions, err := e.lib.Questions(ctx)
		if err != nil {
			return "", err
		}
		for _, q := range questions {
			if q.ID != c.Question.ID {
				continue
			}
			e.see(q.ID, q.LessonID)
			sb.WriteString("用户正在看这道题：\n")
			fmt.Fprintf(&sb, "<question id=%q>\n题干：%s\n", q.ID, q.Stem)
			for i, o := range q.Options {
				fmt.Fprintf(&sb, "%c. %s\n", 'A'+i, o)
			}
			fmt.Fprintf(&sb, "标准答案：%s\n解析：%s\n", letters(q.Answer), q.Explanation)
			if len(c.Question.Selected) > 0 {
				fmt.Fprintf(&sb, "用户选了：%s\n", letters(c.Question.Selected))
			}
			if q.LessonID != "" {
				fmt.Fprintf(&sb, "出自小节 lesson_id=%s\n", q.LessonID)
			}
			sb.WriteString("</question>\n")
			break
		}
	}
	if c.BankID != "" {
		fmt.Fprintf(&sb, "用户当前所在的题库 bank_id=%s；工具默认只在这个题库里查。\n", c.BankID)
	}
	return strings.TrimSpace(sb.String()), nil
}

func letters(idx []int) string {
	var parts []string
	for _, i := range idx {
		if i >= 0 && i < 26 {
			parts = append(parts, string(rune('A'+i)))
		}
	}
	return strings.Join(parts, "")
}

// errorEvent maps a failure to the event the client shows.
func errorEvent(err error) Error {
	switch {
	case errors.Is(err, llm.ErrBudgetExceeded):
		return Error{Code: "budget_exceeded", Message: "今日的 AI 额度已用完，明天再试，或到后台调高每日额度。"}
	case errors.Is(err, llm.ErrRefused):
		return Error{Code: "refused", Message: "模型拒绝回答这个问题，换个问法试试。"}
	case errors.Is(err, context.DeadlineExceeded):
		return Error{Code: "timeout", Message: "回答超时了，请重试。"}
	case strings.Contains(err.Error(), "anthropic") || strings.Contains(err.Error(), "no conversational client"):
		return Error{Code: "unavailable", Message: "助手暂时连不上模型，请稍后再试。"}
	}
	return Error{Code: "internal", Message: "助手出错了，请稍后再试。"}
}
