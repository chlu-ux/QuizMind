package httpapi_test

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/chlu-ux/quizmind/server/internal/llm"
	"github.com/chlu-ux/quizmind/server/internal/llm/fake"
)

// The quote really occurs in the test document (see doc in httpapi_test.go).
const realQuote = "读写锁允许多个读者同时持有锁，但写者必须独占整个资源。"

func q1(stem string, answer int) map[string]any {
	return map[string]any{
		"type": "single", "stem": stem, "options": []string{"多个读者可以同时持有读锁", "同一时刻只允许一个读者", "写者可以与读者并行执行", "读写锁不允许写者进入"},
		"answer_index": answer, "explanation": "读写锁允许多个读者同时持有锁。", "difficulty": 2, "tags": []string{"锁"}, "source_quote": realQuote,
	}
}

func withReplaces(q map[string]any, id string) map[string]any {
	q["replaces"] = id
	return q
}

func proposeCall(lessonID string, qs ...map[string]any) fake.Call {
	b, _ := json.Marshal(map[string]any{"lesson_id": lessonID, "questions": qs})
	return fake.Call{Name: "propose_questions", Input: string(b)}
}

// createChat runs one create-mode conversation to its end and returns the events.
func (s *server) createChat(t *testing.T, convID string) []sseEvent {
	t.Helper()
	body, _ := json.Marshal(map[string]any{"conversation_id": convID, "mode": "create", "device_id": "dev-1",
		"messages": []map[string]string{{"role": "user", "content": "出一道题"}}})
	resp := s.agentReq(t, "POST", "/api/v1/agent/chat", appToken, string(body))
	defer resp.Body.Close()
	require.Equal(t, 200, resp.StatusCode)
	events, _ := readSSE(t, resp)
	return events
}

type draftJSON struct {
	DraftID  string `json:"draft_id"`
	LessonID string `json:"lesson_id"`
	Stem     string
	Verified bool
}

func (s *server) draftsOf(t *testing.T, convID string) []draftJSON {
	t.Helper()
	resp := s.agentReq(t, "GET", "/api/v1/agent/drafts?conversation_id="+convID, appToken, "")
	defer resp.Body.Close()
	require.Equal(t, 200, resp.StatusCode)
	var out struct{ Drafts []draftJSON }
	require.NoError(t, json.NewDecoder(resp.Body).Decode(&out))
	return out.Drafts
}

func (s *server) draftIDs(t *testing.T, convID string) []string {
	t.Helper()
	var ids []string
	for _, d := range s.draftsOf(t, convID) {
		ids = append(ids, d.DraftID)
	}
	return ids
}

// toolResultsOf returns the tool results in the last user message of a request.
func toolResultsOf(req llm.ChatRequest) []string {
	last := req.Messages[len(req.Messages)-1]
	var out []string
	for _, b := range last.Blocks {
		if b.Kind == llm.BlockToolResult {
			out = append(out, b.Text)
		}
	}
	return out
}

// createFixture is a server with one published question, its lesson and an assistant model.
func createFixture(t *testing.T, conv *fake.Converser) (*server, string) {
	t.Helper()
	s := newServer(t)
	s.publishOne(t)
	var lessons lessonsPage
	s.do(t, "GET", "/api/v1/lessons", "", 200, &lessons)
	enableAgent(t, s, conv)
	s.guard.SetLimits(llm.Limits{MaxConcurrency: 4})
	return s, lessons.Items[0].ID
}

func TestAgentCreateMode_ProposeFixAndKeepDraftsPrivate(t *testing.T) {
	var lesson string
	var secondTurn []string
	conv := fake.NewConverser(func(n int, req llm.ChatRequest) fake.Turn {
		switch n {
		case 0:
			fabricated := q1("读写锁中读者与写者的关系是怎样的？", 0)
			fabricated["source_quote"] = "这句话在讲义里根本不存在，是模型编出来的"
			return fake.Turn{Calls: []fake.Call{proposeCall(lesson, q1("关于读写锁的并发特性，下列哪项描述是正确的？", 0), fabricated)}}
		case 1:
			secondTurn = toolResultsOf(req)
			// The fabricated quote was refused with a reason; fix it and propose again.
			return fake.Turn{Calls: []fake.Call{proposeCall(lesson, q1("读写锁中读者与写者之间的关系是怎样的？", 0))}}
		}
		return fake.Turn{Text: "出了 2 道题。"}
	})
	s, lessonID := createFixture(t, conv)
	lesson = lessonID
	var banksBefore []struct {
		QuestionCount int64 `json:"question_count"`
	}
	s.do(t, "GET", "/api/v1/banks", "", 200, &banksBefore)

	events := s.createChat(t, "conv-1")
	var draftEvents []sseEvent
	for _, e := range events {
		if e.Name == "drafts" {
			draftEvents = append(draftEvents, e)
		}
	}
	assert.Equal(t, "done", events[len(events)-1].Name)
	require.Len(t, draftEvents, 2, "one drafts event per propose call that made drafts")
	first := draftEvents[0].Data["drafts"].([]any)
	require.Len(t, first, 1, "the fabricated one is not in it")
	d := first[0].(map[string]any)
	assert.Equal(t, lesson, d["lesson_id"])
	assert.Equal(t, false, d["verified"], "no validator is bound")
	assert.Equal(t, realQuote, d["source_quote"])

	// The model was told why the fabricated question failed, in words it can act on.
	require.Len(t, secondTurn, 1)
	assert.Contains(t, secondTurn[0], `"ok":true`)
	assert.Contains(t, secondTurn[0], "source_quote")
	assert.Contains(t, secondTurn[0], "逐字摘抄")

	// The chat can get its cards back.
	require.Len(t, s.draftsOf(t, "conv-1"), 2)
	assert.Empty(t, s.draftsOf(t, "another-conversation"))

	// Drafts stay out of everything else: the review queue, the question count, the sync feed.
	var all struct{ Total int }
	s.do(t, "GET", "/admin/questions", "", 200, &all)
	assert.Equal(t, 1, all.Total, "only the published question")
	s.do(t, "GET", "/admin/questions?status=needs_review", "", 200, &all)
	assert.Equal(t, 0, all.Total)
	s.do(t, "GET", "/admin/questions?source=agent", "", 200, &all)
	assert.Equal(t, 0, all.Total, "drafts are listed only when asked for by status")
	s.do(t, "GET", "/admin/questions?status=draft&source=agent", "", 200, &all)
	assert.Equal(t, 2, all.Total)
	var banksAfter []struct {
		QuestionCount int64 `json:"question_count"`
	}
	s.do(t, "GET", "/api/v1/banks", "", 200, &banksAfter)
	assert.Equal(t, banksBefore, banksAfter)
	var sync struct{ Items []struct{ ID string } }
	s.do(t, "GET", "/api/v1/sync/questions?since=0", "", 200, &sync)
	assert.Len(t, sync.Items, 1)
	var bankView []struct {
		Counts map[string]int64 `json:"question_counts"`
	}
	s.do(t, "GET", "/admin/banks", "", 200, &bankView)
	assert.EqualValues(t, 2, bankView[0].Counts["draft"], "drafts are a count of their own")
	assert.EqualValues(t, 0, bankView[0].Counts["needs_review"])
}

func TestAgentDrafts_AcceptDiscardAndAuth(t *testing.T) {
	var lesson string
	conv := fake.NewConverser(func(n int, req llm.ChatRequest) fake.Turn {
		if n == 0 {
			return fake.Turn{Calls: []fake.Call{proposeCall(lesson,
				q1("关于读写锁的并发特性，下列哪项描述是正确的？", 0),
				q1("在多读少写的场景中，读写锁相比互斥锁的优势是什么？", 0))}}
		}
		return fake.Turn{Text: "好了。"}
	})
	s, lessonID := createFixture(t, conv)
	lesson = lessonID
	s.createChat(t, "conv-2")
	drafts := s.draftIDs(t, "conv-2")
	require.Len(t, drafts, 2)
	keep, drop := drafts[0], drafts[1]

	post := func(path, token string, want int) map[string]any {
		resp := s.agentReq(t, "POST", path, token, "")
		defer resp.Body.Close()
		require.Equal(t, want, resp.StatusCode, path)
		var out map[string]any
		_ = json.NewDecoder(resp.Body).Decode(&out)
		return out
	}
	post("/api/v1/agent/drafts/"+keep+"/accept", "", 401)
	post("/api/v1/agent/drafts/"+keep+"/accept", "wrong", 401)
	post("/api/v1/agent/drafts/nope/accept", appToken, 404)

	// Accepting sends it to the review queue, not to the learners.
	assert.Equal(t, "needs_review", post("/api/v1/agent/drafts/"+keep+"/accept", appToken, 200)["status"])
	post("/api/v1/agent/drafts/"+keep+"/accept", appToken, 400)
	post("/api/v1/agent/drafts/"+keep+"/discard", appToken, 400)
	var queue struct {
		Total int
		Items []struct {
			ID               string
			GenPromptVersion string `json:"gen_prompt_version"`
		}
	}
	s.do(t, "GET", "/admin/questions?status=needs_review", "", 200, &queue)
	require.Equal(t, 1, queue.Total)
	assert.Equal(t, keep, queue.Items[0].ID)
	assert.Equal(t, "agent.v1", queue.Items[0].GenPromptVersion)
	s.do(t, "GET", "/admin/questions?status=needs_review&source=agent", "", 200, &queue)
	assert.Equal(t, 1, queue.Total, "the review page can filter on the assistant as the source")
	var sync struct{ Items []struct{ ID string } }
	s.do(t, "GET", "/api/v1/sync/questions?since=0", "", 200, &sync)
	assert.Len(t, sync.Items, 1, "still not published")

	// A reviewer approves it like any other question, and then it syncs.
	s.do(t, "POST", "/admin/questions/"+keep+"/approve", "", 200, nil)
	s.do(t, "GET", "/api/v1/sync/questions?since=0", "", 200, &sync)
	assert.Len(t, sync.Items, 2)

	assert.Equal(t, "rejected", post("/api/v1/agent/drafts/"+drop+"/discard", appToken, 200)["status"])
	post("/api/v1/agent/drafts/"+drop+"/accept", appToken, 400)
	assert.Empty(t, s.draftsOf(t, "conv-2"), "nothing is waiting any more")
}

func TestAgentCreateMode_DuplicatesReplacementsAndUnknownLessons(t *testing.T) {
	var lesson, oldDraft string
	var s *server
	var results [][]string
	conv := fake.NewConverser(func(n int, req llm.ChatRequest) fake.Turn {
		if n > 0 {
			results = append(results, toolResultsOf(req))
		}
		switch n {
		case 0:
			return fake.Turn{Calls: []fake.Call{proposeCall(lesson, q1("关于读写锁的并发特性，下列哪项描述是正确的？", 0))}}
		case 1: // the same question again, a lesson that does not exist, and a draft that is not ours
			return fake.Turn{Calls: []fake.Call{
				proposeCall(lesson, q1("关于读写锁的并发特性，下列哪项描述是正确的？", 0)),
				proposeCall("no-such-lesson", q1("另一个完全不同的问题是什么呢？", 0)),
				proposeCall(lesson, withReplaces(q1("读写锁的写者具有怎样的访问权限？", 0), "someone-elses")),
			}}
		case 2: // replace our own draft with an improved one
			drafts := s.draftIDs(t, "conv-3")
			require.Len(t, drafts, 1)
			oldDraft = drafts[0]
			return fake.Turn{Calls: []fake.Call{proposeCall(lesson, withReplaces(q1("关于读写锁的并发特性，下列哪项描述是正确的？（改进版）", 0), oldDraft))}}
		}
		return fake.Turn{Text: "好了。"}
	})
	var lessonID string
	s, lessonID = createFixture(t, conv)
	lesson = lessonID
	s.createChat(t, "conv-3")

	require.Len(t, results, 3)
	assert.Contains(t, results[0][0], "draft_id")
	// The three calls of one turn come back together: duplicate, unknown lesson, foreign draft.
	require.Len(t, results[1], 3)
	assert.Contains(t, results[1][0], "与已有题目重复")
	assert.Contains(t, results[1][1], "没有 id 为")
	assert.Contains(t, results[1][2], "不属于本对话")
	assert.Contains(t, results[2][0], `"ok":true`, "an improved version may replace its own earlier draft")

	drafts := s.draftsOf(t, "conv-3")
	require.Len(t, drafts, 1)
	assert.NotEqual(t, oldDraft, drafts[0].DraftID)
	assert.Contains(t, drafts[0].Stem, "改进版")
	var old struct{ Status string }
	s.do(t, "GET", "/admin/questions/"+oldDraft, "", 200, &old)
	assert.Equal(t, "rejected", old.Status, "the replaced draft is withdrawn")
}

func TestAgentCreateMode_IndependentVerification(t *testing.T) {
	var lesson string
	var results []string
	conv := fake.NewConverser(func(n int, req llm.ChatRequest) fake.Turn {
		if n == 0 {
			// The key of the first says 0 where the validator says 1; the second agrees with it.
			disagree := q1("关于读写锁的并发特性，下列哪项描述是正确的？", 0)
			agree := q1("读写锁对写者的访问限制是怎样规定的呢？", 1)
			return fake.Turn{Calls: []fake.Call{proposeCall(lesson, disagree, agree)}}
		}
		results = toolResultsOf(req)
		return fake.Turn{Text: "好了。"}
	})
	s, lessonID := createFixture(t, conv)
	lesson = lessonID

	// A second model that answers option 1 whatever it is asked, and must never see the answer key.
	var asked []string
	s.reg.Set(llm.RoleValidator, s.guard.Wrap(llm.RoleValidator, fake.New(func(req llm.JSONRequest) (any, error) {
		asked = append(asked, req.User)
		return map[string]any{"answer_index": 1}, nil
	})))

	events := s.createChat(t, "conv-4")

	require.Len(t, results, 1)
	assert.Contains(t, results[0], "独立复核认为正确答案是")
	assert.Contains(t, results[0], `"ok":true`)
	require.Len(t, asked, 2)
	for _, a := range asked {
		assert.NotContains(t, a, "读写锁允许多个读者同时持有锁。", "the explanation (an answer) is not shown")
	}
	drafts := s.draftsOf(t, "conv-4")
	require.Len(t, drafts, 1)
	assert.True(t, drafts[0].Verified)
	for _, e := range events {
		if e.Name == "drafts" {
			assert.Equal(t, true, e.Data["drafts"].([]any)[0].(map[string]any)["verified"])
		}
	}

	var st struct{ Verified bool }
	resp := s.agentReq(t, "GET", "/api/v1/agent/status", appToken, "")
	defer resp.Body.Close()
	require.NoError(t, json.NewDecoder(resp.Body).Decode(&st))
	assert.True(t, st.Verified, "status tells the apps a second model checks the questions")
}

func TestAgentModes_ToolsDependOnTheMode(t *testing.T) {
	conv := fake.NewConverser(func(int, llm.ChatRequest) fake.Turn { return fake.Turn{Text: "ok"} })
	s := newServer(t)
	enableAgent(t, s, conv)
	s.guard.SetLimits(llm.Limits{MaxConcurrency: 4})

	chat := func(mode string) {
		body, _ := json.Marshal(map[string]any{"mode": mode, "messages": []map[string]string{{"role": "user", "content": "hi"}}})
		resp := s.agentReq(t, "POST", "/api/v1/agent/chat", appToken, string(body))
		defer resp.Body.Close()
		require.Equal(t, 200, resp.StatusCode)
		readSSE(t, resp)
	}
	chat("learn")
	chat("")
	chat("create")
	reqs := conv.Requests()
	require.Len(t, reqs, 3)
	toolNames := func(r llm.ChatRequest) string {
		var names []string
		for _, t := range r.Tools {
			names = append(names, t.Name)
		}
		return strings.Join(names, ",")
	}
	assert.NotContains(t, toolNames(reqs[0]), "propose_questions")
	assert.NotContains(t, toolNames(reqs[1]), "propose_questions", "learn is the default")
	assert.Contains(t, toolNames(reqs[2]), "propose_questions")
	assert.Contains(t, toolNames(reqs[2]), "list_drafts")
	assert.Contains(t, strings.Join(reqs[2].System, "\n"), "出题模式")
	assert.NotContains(t, strings.Join(reqs[0].System, "\n"), "出题模式")
}

func TestAgentDrafts_StaleOnesAreRetiredWhenAChatStarts(t *testing.T) {
	var lesson string
	conv := fake.NewConverser(func(n int, req llm.ChatRequest) fake.Turn {
		if n == 0 {
			return fake.Turn{Calls: []fake.Call{proposeCall(lesson, q1("关于读写锁的并发特性，下列哪项描述是正确的？", 0))}}
		}
		return fake.Turn{Text: "ok"}
	})
	s, lessonID := createFixture(t, conv)
	lesson = lessonID
	s.createChat(t, "conv-5")
	require.Len(t, s.draftsOf(t, "conv-5"), 1)

	old := time.Now().Add(-8 * 24 * time.Hour).UnixMilli()
	_, err := s.db.Write.Exec(`UPDATE agent_draft SET created_at = ?`, old)
	require.NoError(t, err)
	s.createChat(t, "conv-6") // any new conversation does the cleanup
	assert.Empty(t, s.draftsOf(t, "conv-5"))
	var status string
	require.NoError(t, s.db.Read.QueryRow(`SELECT status FROM question WHERE id IN (SELECT question_id FROM agent_draft)`).Scan(&status))
	assert.Equal(t, "retired", status)
}
