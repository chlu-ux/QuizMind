package agent_test

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/chlu-ux/quizmind/server/internal/agent"
	"github.com/chlu-ux/quizmind/server/internal/llm"
	"github.com/chlu-ux/quizmind/server/internal/llm/fake"
)

type memLib struct {
	banks     []agent.Bank
	lessons   []agent.Lesson
	questions []agent.Question
	attempts  []agent.Attempt
}

func (m *memLib) Banks(context.Context) ([]agent.Bank, error)         { return m.banks, nil }
func (m *memLib) Lessons(context.Context) ([]agent.Lesson, error)     { return m.lessons, nil }
func (m *memLib) Questions(context.Context) ([]agent.Question, error) { return m.questions, nil }
func (m *memLib) Attempts(context.Context) ([]agent.Attempt, error)   { return m.attempts, nil }

func testLib() *memLib {
	return &memLib{
		banks: []agent.Bank{{ID: "b1", Title: "软件设计师"}},
		lessons: []agent.Lesson{
			{ID: "L1", BankID: "b1", DocumentID: "d1", DocumentTitle: "操作系统", HeadingPath: "考点精讲 > 2.1 操作系统概述",
				Text: "操作系统是管理计算机硬件与软件资源的程序。它提供进程管理、存储管理和文件管理等功能。"},
			{ID: "L2", BankID: "b1", DocumentID: "d1", DocumentTitle: "操作系统", HeadingPath: "考点精讲 > 2.2 进程调度",
				Text: "进程调度算法包括先来先服务、短作业优先、时间片轮转和优先级调度。时间片轮转适合分时系统。"},
			{ID: "L3", BankID: "b1", DocumentID: "d2", DocumentTitle: "数据库", HeadingPath: "考点精讲 > 3.1 关系模型",
				Text: "关系模型用二维表表示实体与联系，范式用来消除数据冗余。"},
		},
		questions: []agent.Question{
			{ID: "Q1", BankID: "b1", LessonID: "L2", Type: "single", Stem: "时间片轮转调度适用于哪种系统？",
				Options: []string{"分时系统", "批处理系统", "实时系统", "嵌入式系统"}, Answer: []int{0}, Explanation: "时间片轮转适合分时系统。"},
			{ID: "Q2", BankID: "b1", LessonID: "L2", Type: "single", Stem: "短作业优先调度的缺点是什么？",
				Options: []string{"长作业可能饥饿", "开销大", "不能抢占", "无法实现"}, Answer: []int{0}, Explanation: "长作业可能一直得不到调度。"},
			{ID: "Q3", BankID: "b1", LessonID: "L3", Type: "judge", Stem: "范式用来消除数据冗余。",
				Options: []string{"对", "错"}, Answer: []int{0}, Explanation: "范式的目的之一。"},
		},
		attempts: []agent.Attempt{
			{"Q1", false, 1}, {"Q1", false, 2}, {"Q1", true, 3},
			{"Q2", true, 4},
			{"Q3", false, 5}, {"Q3", false, 6}, {"Q3", false, 7},
		},
	}
}

type recorder struct{ events []agent.Event }

func (r *recorder) emit(e agent.Event) { r.events = append(r.events, e) }

func (r *recorder) names() []string {
	var out []string
	for _, e := range r.events {
		n := e.EventName()
		if n == "delta" && len(out) > 0 && out[len(out)-1] == "delta" {
			continue
		}
		out = append(out, n)
	}
	return out
}

func (r *recorder) text() string {
	var sb strings.Builder
	for _, e := range r.events {
		if d, ok := e.(agent.Delta); ok {
			sb.WriteString(d.Text)
		}
	}
	return sb.String()
}

func (r *recorder) tools() []agent.ToolEvent {
	var out []agent.ToolEvent
	for _, e := range r.events {
		if t, ok := e.(agent.ToolEvent); ok {
			out = append(out, t)
		}
	}
	return out
}

func (r *recorder) last() agent.Event { return r.events[len(r.events)-1] }

func userMsg(text string) []llm.Message {
	return []llm.Message{{Role: "user", Blocks: []llm.Block{{Kind: llm.BlockText, Text: text}}}}
}

func newAgent(c llm.Converser, lib agent.Library) *agent.Agent {
	return &agent.Agent{Conv: c, Lib: lib, Now: func() time.Time { return time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC) }}
}

func toolResults(req llm.ChatRequest) []llm.Block {
	var out []llm.Block
	for _, m := range req.Messages {
		for _, b := range m.Blocks {
			if b.Kind == llm.BlockToolResult {
				out = append(out, b)
			}
		}
	}
	return out
}

func TestRun_LookupThenAnswerWithCheckedLinks(t *testing.T) {
	conv := fake.Script(
		fake.Turn{Text: "我先查一下。", Calls: []fake.Call{{Name: "search_lessons", Input: `{"query":"进程调度"}`}},
			Usage: llm.Usage{InputTokens: 100, OutputTokens: 10}},
		fake.Turn{Calls: []fake.Call{{Name: "get_lesson", Input: `{"lesson_id":"L2"}`}}, Usage: llm.Usage{InputTokens: 150, OutputTokens: 8, CachedTokens: 100}},
		fake.Turn{Text: "常见算法见[进程调度](lesson:L2)，不要看[编造的](lesson:ZZZ)。", Usage: llm.Usage{InputTokens: 300, OutputTokens: 40, CachedTokens: 150}},
	)
	rec := &recorder{}
	newAgent(conv, testLib()).Run(context.Background(), agent.Request{ConversationID: "c1", Messages: userMsg("讲讲进程调度")}, rec.emit)

	assert.Equal(t, []string{"start", "delta", "tool", "tool", "tool", "tool", "delta", "done"}, rec.names())
	assert.Equal(t, agent.Start{ConversationID: "c1"}, rec.events[0])
	assert.Equal(t, "我先查一下。常见算法见[进程调度](lesson:L2)，不要看编造的。", rec.text(), "an invented link keeps its label only")

	tools := rec.tools()
	require.Len(t, tools, 4)
	assert.Equal(t, agent.ToolEvent{ID: "call_0_0", Name: "search_lessons", Label: "在讲义里查找「进程调度」", Status: "running"}, tools[0])
	assert.Equal(t, "done", tools[1].Status)
	assert.Equal(t, "读取讲义「2.2 进程调度」", tools[2].Label)

	assert.Equal(t, agent.Done{Stop: "end_turn", Usage: agent.Usage{Input: 550, Output: 58, Cached: 250}}, rec.last())

	// The model saw the first tool's result before its second call, and the lesson text was wrapped.
	reqs := conv.Requests()
	require.Len(t, reqs, 3)
	assert.Len(t, reqs[0].Tools, 6)
	assert.Contains(t, toolResults(reqs[1])[0].Text, `"lesson_id":"L2"`)
	assert.Contains(t, toolResults(reqs[2])[1].Text, `<lesson id="L2"`)
	assert.Contains(t, reqs[0].System[1], "2026年10月8日")
}

func TestRun_ToolMistakesGoBackToTheModel(t *testing.T) {
	conv := fake.Script(
		fake.Turn{Calls: []fake.Call{
			{Name: "get_lesson", Input: `{"lesson_id":"nope"}`},
			{Name: "no_such_tool", Input: `{}`},
			{Name: "search_lessons", Input: `not json`},
			{Name: "search_lessons", Input: `{"query":""}`},
		}},
		fake.Turn{Text: "好的。"},
	)
	rec := &recorder{}
	newAgent(conv, testLib()).Run(context.Background(), agent.Request{ConversationID: "c", Messages: userMsg("hi")}, rec.emit)

	results := toolResults(conv.Requests()[1])
	require.Len(t, results, 4)
	for _, r := range results {
		assert.True(t, r.IsError)
	}
	assert.Contains(t, results[0].Text, "没有 id 为")
	assert.Contains(t, results[1].Text, "可用的工具")
	assert.Contains(t, results[2].Text, "JSON")
	assert.Contains(t, results[3].Text, "query")
	assert.IsType(t, agent.Done{}, rec.last(), "mistakes do not end the conversation")
	for _, tl := range rec.tools()[4:] {
		assert.Equal(t, "error", tl.Status)
	}
}

func TestRun_OutOfRoundsMakesTheModelAnswerWithoutTools(t *testing.T) {
	conv := fake.NewConverser(func(n int, req llm.ChatRequest) fake.Turn {
		if len(req.Tools) == 0 {
			return fake.Turn{Text: "总结如下。"}
		}
		return fake.Turn{Calls: []fake.Call{{Name: "list_outline", Input: `{}`}}}
	})
	rec := &recorder{}
	a := newAgent(conv, testLib())
	a.MaxRounds = 2
	a.Run(context.Background(), agent.Request{ConversationID: "c", Messages: userMsg("hi")}, rec.emit)

	reqs := conv.Requests()
	require.Len(t, reqs, 3, "two rounds with tools, then one without")
	assert.Empty(t, reqs[2].Tools)
	last := reqs[2].Messages[len(reqs[2].Messages)-1]
	assert.Equal(t, "user", last.Role)
	assert.Equal(t, llm.BlockToolResult, last.Blocks[0].Kind, "the nudge joins the tool results instead of a second user message")
	assert.Equal(t, llm.BlockText, last.Blocks[len(last.Blocks)-1].Kind)
	assert.Equal(t, "总结如下。", rec.text())
	assert.Equal(t, "max_rounds", rec.last().(agent.Done).Stop)
}

func TestRun_ModelErrors(t *testing.T) {
	cases := []struct {
		name string
		err  error
		code string
	}{
		{"budget", llm.ErrBudgetExceeded, "budget_exceeded"},
		{"refused", fmt.Errorf("%w: x", llm.ErrRefused), "refused"},
		{"timeout", context.DeadlineExceeded, "timeout"},
		{"endpoint", fmt.Errorf("anthropic stream: 500"), "unavailable"},
		{"other", fmt.Errorf("boom"), "internal"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := &recorder{}
			newAgent(fake.Script(fake.Turn{Err: tc.err}), testLib()).Run(context.Background(), agent.Request{ConversationID: "c", Messages: userMsg("hi")}, rec.emit)
			assert.Equal(t, []string{"start", "error"}, rec.names())
			e := rec.last().(agent.Error)
			assert.Equal(t, tc.code, e.Code)
			assert.NotEmpty(t, e.Message)
		})
	}
}

func TestRun_TruncatedAnswerEndsWithMaxTokens(t *testing.T) {
	rec := &recorder{}
	newAgent(fake.Script(fake.Turn{Text: "说到一半", Err: nil, Stop: "max_tokens"}), testLib()).
		Run(context.Background(), agent.Request{ConversationID: "c", Messages: userMsg("hi")}, rec.emit)
	// A truncated turn without an error from the client is just a normal end; the Anthropic client
	// reports truncation as ErrTruncated, covered next.
	assert.IsType(t, agent.Done{}, rec.last())

	rec = &recorder{}
	newAgent(fake.Script(fake.Turn{Err: llm.ErrTruncated}), testLib()).Run(context.Background(), agent.Request{ConversationID: "c", Messages: userMsg("hi")}, rec.emit)
	assert.Equal(t, "max_tokens", rec.last().(agent.Done).Stop)
}

func TestRun_ClientGoneSaysNothingMore(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	conv := fake.NewConverser(func(int, llm.ChatRequest) fake.Turn {
		cancel() // the client disconnects while the model is working
		return fake.Turn{Err: context.Canceled}
	})
	rec := &recorder{}
	newAgent(conv, testLib()).Run(ctx, agent.Request{ConversationID: "c", Messages: userMsg("hi")}, rec.emit)
	assert.Equal(t, []string{"start"}, rec.names(), "no error event for a client that left")
}

func TestRun_ContextIsInTheInstructions(t *testing.T) {
	conv := fake.Script(fake.Turn{Text: "ok"})
	rec := &recorder{}
	newAgent(conv, testLib()).Run(context.Background(), agent.Request{
		ConversationID: "c", Messages: userMsg("为什么选这个"),
		Context: agent.Context{BankID: "b1", LessonID: "L2", Question: &agent.QuestionContext{ID: "Q1", Selected: []int{1}}},
	}, rec.emit)
	sys := strings.Join(conv.Requests()[0].System, "\n")
	assert.Contains(t, sys, "时间片轮转和优先级调度")
	assert.Contains(t, sys, "标准答案：A")
	assert.Contains(t, sys, "用户选了：B")
	assert.Contains(t, sys, "bank_id=b1")
}

func TestRun_ContextIdsMakeLinksValid(t *testing.T) {
	conv := fake.Script(fake.Turn{Text: "见[本节](lesson:L2)和[原题](question:Q1)。"})
	rec := &recorder{}
	newAgent(conv, testLib()).Run(context.Background(), agent.Request{
		ConversationID: "c", Messages: userMsg("hi"), Context: agent.Context{LessonID: "L2", Question: &agent.QuestionContext{ID: "Q1"}},
	}, rec.emit)
	assert.Equal(t, "见[本节](lesson:L2)和[原题](question:Q1)。", rec.text())
}

func TestRun_LinksSplitAcrossChunksAreStillChecked(t *testing.T) {
	// The fake streams three characters at a time, so this link is split in several places.
	conv := fake.Script(fake.Turn{Text: "A [第一个](lesson:BAD1) B [第二个](question:BAD2)\n[不是链接] 结束 [x]"})
	rec := &recorder{}
	newAgent(conv, testLib()).Run(context.Background(), agent.Request{ConversationID: "c", Messages: userMsg("hi")}, rec.emit)
	assert.Equal(t, "A 第一个 B 第二个\n[不是链接] 结束 [x]", rec.text())
}

func toolRun(t *testing.T, lib *memLib, name, input string, bank string) (string, bool) {
	t.Helper()
	conv := fake.Script(fake.Turn{Calls: []fake.Call{{Name: name, Input: input}}}, fake.Turn{Text: "ok"})
	rec := &recorder{}
	newAgent(conv, lib).Run(context.Background(), agent.Request{ConversationID: "c", Messages: userMsg("hi"), Context: agent.Context{BankID: bank}}, rec.emit)
	res := toolResults(conv.Requests()[1])
	require.Len(t, res, 1)
	return res[0].Text, res[0].IsError
}

func TestTool_SearchLessonsRanksTitleHitsAndFindsChinese(t *testing.T) {
	text, isErr := toolRun(t, testLib(), "search_lessons", `{"query":"调度算法"}`, "")
	require.False(t, isErr)
	var out struct {
		Results []struct {
			ID      string `json:"lesson_id"`
			Snippet string `json:"snippet"`
		} `json:"results"`
	}
	require.NoError(t, json.Unmarshal([]byte(text), &out))
	require.NotEmpty(t, out.Results)
	assert.Equal(t, "L2", out.Results[0].ID, "the scheduling section ranks first")
	assert.Contains(t, out.Results[0].Snippet, "调度")

	text, _ = toolRun(t, testLib(), "search_lessons", `{"query":"量子纠缠"}`, "")
	assert.Contains(t, text, "没有找到")
}

func TestTool_BankDefaultsToTheContext(t *testing.T) {
	lib := testLib()
	lib.banks = append(lib.banks, agent.Bank{ID: "b2", Title: "其他"})
	lib.lessons = append(lib.lessons, agent.Lesson{ID: "X1", BankID: "b2", DocumentID: "d9", DocumentTitle: "另一本", HeadingPath: "进程", Text: "进程调度 在另一个题库里"})
	text, _ := toolRun(t, lib, "search_lessons", `{"query":"进程调度"}`, "b1")
	assert.NotContains(t, text, "X1")
	text, _ = toolRun(t, lib, "search_lessons", `{"query":"进程调度","bank_id":"b2"}`, "b1")
	assert.Contains(t, text, "X1")
	assert.NotContains(t, text, `"L2"`)
}

func TestTool_PickQuestionsHidesAnswers(t *testing.T) {
	text, isErr := toolRun(t, testLib(), "pick_questions", `{"lesson_id":"L2","count":5}`, "")
	require.False(t, isErr)
	assert.Contains(t, text, "时间片轮转调度适用于哪种系统")
	assert.NotContains(t, text, "answer")
	assert.NotContains(t, text, "时间片轮转适合分时系统", "the explanation is an answer too")
	assert.NotContains(t, text, "Q3", "other lessons' questions stay out")
}

func TestTool_PickWeakQuestionsOnlyThoseGoneWrong(t *testing.T) {
	text, _ := toolRun(t, testLib(), "pick_questions", `{"weak":true,"count":10}`, "")
	var out struct {
		Questions []struct {
			ID string `json:"question_id"`
		}
	}
	require.NoError(t, json.Unmarshal([]byte(text), &out))
	var ids []string
	for _, q := range out.Questions {
		ids = append(ids, q.ID)
	}
	assert.Equal(t, []string{"Q3", "Q1"}, ids, "Q3 (3 wrong of 3) before Q1 (2 wrong of 3); Q2 was always right")
}

func TestTool_WeakPoints(t *testing.T) {
	text, isErr := toolRun(t, testLib(), "get_weak_points", `{}`, "")
	require.False(t, isErr)
	var out struct {
		Questions []struct {
			ID    string `json:"question_id"`
			Wrong int    `json:"recent_wrong"`
		} `json:"weak_questions"`
		Lessons []struct {
			ID       string `json:"lesson_id"`
			Accuracy int    `json:"accuracy_percent"`
		} `json:"weak_lessons"`
	}
	require.NoError(t, json.Unmarshal([]byte(text), &out))
	require.Len(t, out.Questions, 2)
	assert.Equal(t, "Q3", out.Questions[0].ID)
	assert.Equal(t, 3, out.Questions[0].Wrong)
	require.Len(t, out.Lessons, 2)
	assert.Equal(t, "L3", out.Lessons[0].ID)
	assert.Equal(t, 0, out.Lessons[0].Accuracy)
	assert.Equal(t, "L2", out.Lessons[1].ID)
	assert.Equal(t, 50, out.Lessons[1].Accuracy, "2 of 4 answers to L2's questions were right")

	empty := testLib()
	empty.attempts = nil
	text, _ = toolRun(t, empty, "get_weak_points", `{}`, "")
	assert.Contains(t, text, "还没有足够的作答记录")
}

func TestTool_OutlineListsChaptersWhenTooBig(t *testing.T) {
	text, _ := toolRun(t, testLib(), "list_outline", `{}`, "")
	assert.Contains(t, text, `"lesson_id":"L1"`)
	assert.Contains(t, text, `"questions":2`)

	big := testLib()
	for i := 0; i < 250; i++ {
		big.lessons = append(big.lessons, agent.Lesson{ID: fmt.Sprintf("B%d", i), BankID: "b1", DocumentID: "dbig", DocumentTitle: "大章", HeadingPath: fmt.Sprintf("x > %d", i)})
	}
	text, _ = toolRun(t, big, "list_outline", `{}`, "")
	assert.Contains(t, text, "只列了章节")
	assert.NotContains(t, text, `"lesson_id"`)
	text, _ = toolRun(t, big, "list_outline", `{"document_id":"d1"}`, "")
	assert.Contains(t, text, `"lesson_id":"L2"`)
	assert.NotContains(t, text, "B1")
}

func TestTool_ResultsAreCapped(t *testing.T) {
	lib := testLib()
	lib.lessons[0].Text = strings.Repeat("长", 20000)
	text, _ := toolRun(t, lib, "get_lesson", `{"lesson_id":"L1"}`, "")
	assert.Contains(t, text, "已截断")
	assert.LessOrEqual(t, len([]rune(text)), 6100)
}
