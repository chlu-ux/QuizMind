package httpapi_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/chlu-ux/quizmind/server/internal/llm"
	"github.com/chlu-ux/quizmind/server/internal/llm/fake"
)

func storedBody(conv, mode, text string, extra map[string]any) string {
	m := map[string]any{"conversation_id": conv, "mode": mode, "device_id": "dev-1", "message": map[string]any{"text": text}}
	for k, v := range extra {
		m[k] = v
	}
	b, _ := json.Marshal(m)
	return string(b)
}

// ask sends one message of a stored conversation and reads the answer to its end.
func (s *server) ask(t *testing.T, conv, mode, text string, extra map[string]any) []sseEvent {
	t.Helper()
	resp := s.agentReq(t, "POST", "/api/v1/agent/chat", appToken, storedBody(conv, mode, text, extra))
	defer resp.Body.Close()
	require.Equal(t, 200, resp.StatusCode)
	events, _ := readSSE(t, resp)
	return events
}

type convItem struct {
	ID            string `json:"id"`
	Mode          string `json:"mode"`
	Title         string `json:"title"`
	BankID        string `json:"bank_id"`
	MessageCount  int    `json:"message_count"`
	PendingDrafts int    `json:"pending_drafts"`
	UpdatedAt     int64  `json:"updated_at"`
}

type convPage struct {
	Items   []convItem `json:"items"`
	HasMore bool       `json:"has_more"`
}

type convMessage struct {
	Role  string `json:"role"`
	Text  string `json:"text"`
	Note  string `json:"note"`
	Error string `json:"error"`
	Tools []struct {
		ID, Label, Status string
	} `json:"tools"`
	Drafts []struct {
		DraftID string `json:"draft_id"`
		Stem    string `json:"stem"`
		Phase   string `json:"phase"`
	} `json:"drafts"`
}

type convDetail struct {
	ID       string        `json:"id"`
	Mode     string        `json:"mode"`
	Title    string        `json:"title"`
	BankID   string        `json:"bank_id"`
	Messages []convMessage `json:"messages"`
}

func (s *server) conversations(t *testing.T, query string) convPage {
	t.Helper()
	resp := s.agentReq(t, "GET", "/api/v1/agent/conversations"+query, appToken, "")
	defer resp.Body.Close()
	require.Equal(t, 200, resp.StatusCode)
	var p convPage
	require.NoError(t, json.NewDecoder(resp.Body).Decode(&p))
	return p
}

func (s *server) conversation(t *testing.T, id string, want int) convDetail {
	t.Helper()
	resp := s.agentReq(t, "GET", "/api/v1/agent/conversations/"+id, appToken, "")
	defer resp.Body.Close()
	require.Equal(t, want, resp.StatusCode)
	var d convDetail
	if want == 200 {
		require.NoError(t, json.NewDecoder(resp.Body).Decode(&d))
	}
	return d
}

func roles(req llm.ChatRequest) []string {
	var out []string
	for _, m := range req.Messages {
		var text string
		for _, b := range m.Blocks {
			if b.Kind == llm.BlockText {
				text += b.Text
			}
		}
		out = append(out, m.Role+":"+text)
	}
	return out
}

func TestAgentHistory_ConversationIsKeptAndContinued(t *testing.T) {
	s := newServer(t)
	conv := fake.Script(
		fake.Turn{Text: "我查一下。", Calls: []fake.Call{{Name: "search_lessons", Input: `{"query":"读写锁"}`}}},
		fake.Turn{Text: "读写锁允许多个读者。"},
		fake.Turn{Text: "再讲细一点：读者之间不互斥。"},
	)
	enableAgent(t, s, conv)
	s.guard.SetLimits(llm.Limits{MaxConcurrency: 4})

	assert.Empty(t, s.conversations(t, "").Items, "nothing yet")

	s.ask(t, "c-1", "learn", "  什么是\n读写锁？请讲讲它和互斥锁的区别，以及适合的场景和实现方式  ", map[string]any{"context": map[string]any{}})
	list := s.conversations(t, "")
	require.Len(t, list.Items, 1)
	assert.Equal(t, "c-1", list.Items[0].ID)
	assert.Equal(t, "learn", list.Items[0].Mode)
	assert.Equal(t, 2, list.Items[0].MessageCount)
	assert.Equal(t, "什么是 读写锁？请讲讲它和互斥锁的区别，以及适合的场景和实现…", list.Items[0].Title, "first 30 characters, on one line")

	d := s.conversation(t, "c-1", 200)
	require.Len(t, d.Messages, 2)
	assert.Equal(t, "user", d.Messages[0].Role)
	assert.Equal(t, "assistant", d.Messages[1].Role)
	assert.Equal(t, "我查一下。读写锁允许多个读者。", d.Messages[1].Text)
	require.Len(t, d.Messages[1].Tools, 1)
	assert.Equal(t, "done", d.Messages[1].Tools[0].Status)
	assert.NotEmpty(t, d.Messages[1].Tools[0].Label)

	// A second question carries the first exchange along as text.
	s.ask(t, "c-1", "learn", "再讲细一点", nil)
	reqs := conv.Requests()
	last := reqs[len(reqs)-1]
	got := roles(last)
	require.Len(t, got, 3)
	assert.Contains(t, got[0], "user:什么是")
	assert.Equal(t, "assistant:我查一下。读写锁允许多个读者。", got[1])
	assert.Equal(t, "user:再讲细一点", got[2])
	assert.Len(t, s.conversation(t, "c-1", 200).Messages, 4)
	assert.Len(t, s.conversations(t, "").Items, 1, "still one conversation")
}

func TestAgentHistory_RequestChecks(t *testing.T) {
	s := newServer(t)
	enableAgent(t, s, fake.Script(fake.Turn{Text: "好"}, fake.Turn{Text: "好"}))
	s.guard.SetLimits(llm.Limits{MaxConcurrency: 4})

	post := func(body string, want int) {
		t.Helper()
		resp := s.agentReq(t, "POST", "/api/v1/agent/chat", appToken, body)
		defer resp.Body.Close()
		assert.Equal(t, want, resp.StatusCode, body)
		if want == 200 {
			readSSE(t, resp)
		}
	}
	post(storedBody("", "learn", "你好", nil), 400)                      // a conversation needs an id
	post(storedBody(strings.Repeat("x", 65), "learn", "你好", nil), 400) // …a reasonable one
	post(storedBody("c-1", "learn", "   ", nil), 400)                  // …and words
	post(storedBody("c-1", "chat", "你好", nil), 400)                    // …in a known mode
	assert.Empty(t, s.conversations(t, "").Items, "nothing was kept for the refused ones")

	post(storedBody("c-1", "learn", "你好", nil), 200)
	post(storedBody("c-1", "create", "出题", nil), 400) // a learning conversation stays one
	post(storedBody("c-1", "", "再问", nil), 200)       // no mode: the conversation's own

	// The older form, with the history in the request, keeps nothing.
	post(chatBody("旧形式"), 200)
	assert.Len(t, s.conversations(t, "").Items, 1)
}

func TestAgentHistory_NeedsTheToken(t *testing.T) {
	s := newServer(t)
	enableAgent(t, s, fake.Script(fake.Turn{Text: "好"}))
	s.guard.SetLimits(llm.Limits{MaxConcurrency: 4})
	s.ask(t, "c-1", "learn", "你好", nil)
	for _, c := range []struct{ method, path, body string }{
		{"GET", "/api/v1/agent/conversations", ""},
		{"GET", "/api/v1/agent/conversations/c-1", ""},
		{"PATCH", "/api/v1/agent/conversations/c-1", `{"title":"x"}`},
		{"DELETE", "/api/v1/agent/conversations/c-1", ""},
	} {
		for _, token := range []string{"", "wrong"} {
			resp := s.agentReq(t, c.method, c.path, token, c.body)
			assert.Equal(t, 401, resp.StatusCode, "%s %s with %q", c.method, c.path, token)
			resp.Body.Close()
		}
	}
	s.conversation(t, "c-1", 200)
	s.conversation(t, "nope", 404)
}

func TestAgentHistory_AFailedAnswerIsKeptAndLeftOutOfWhatTheModelSees(t *testing.T) {
	s := newServer(t)
	conv := fake.NewConverser(func(n int, _ llm.ChatRequest) fake.Turn {
		if n == 0 {
			return fake.Turn{Err: llm.ErrBudgetExceeded}
		}
		return fake.Turn{Text: "好"}
	})
	enableAgent(t, s, conv)
	s.guard.SetLimits(llm.Limits{MaxConcurrency: 4})

	events := s.ask(t, "c-1", "learn", "第一问", nil)
	assert.Equal(t, "error", events[len(events)-1].Name)
	d := s.conversation(t, "c-1", 200)
	require.Len(t, d.Messages, 2)
	assert.Contains(t, d.Messages[1].Error, "额度")
	assert.Empty(t, d.Messages[1].Text)

	s.ask(t, "c-1", "learn", "第二问", nil)
	reqs := conv.Requests()
	assert.Equal(t, []string{"user:第一问\n\n第二问"}, roles(reqs[len(reqs)-1]), "the empty answer is skipped and the two questions joined")
	assert.Len(t, s.conversation(t, "c-1", 200).Messages, 4)
}

func TestAgentHistory_StoppingKeepsTheQuestionAndWhatWasWritten(t *testing.T) {
	s := newServer(t)
	conv := fake.Script(fake.Turn{Text: "写到一半"})
	release := conv.Block()
	defer release()
	enableAgent(t, s, conv)
	s.guard.SetLimits(llm.Limits{MaxConcurrency: 4})

	ctx, cancel := context.WithCancel(context.Background())
	req, err := http.NewRequestWithContext(ctx, "POST", s.ts.URL+"/api/v1/agent/chat", strings.NewReader(storedBody("c-1", "learn", "讲讲", nil)))
	require.NoError(t, err)
	req.Header.Set("Authorization", "Bearer "+appToken)
	req.Header.Set("Content-Type", "application/json")
	done := make(chan struct{})
	go func() {
		defer close(done)
		if resp, err := http.DefaultClient.Do(req); err == nil {
			resp.Body.Close()
		}
	}()
	require.Eventually(t, func() bool { return len(conv.Requests()) == 1 }, 5*time.Second, 10*time.Millisecond)
	cancel() // the learner presses stop: the connection closes
	<-done

	require.Eventually(t, func() bool { return len(s.conversation(t, "c-1", 200).Messages) == 2 }, 5*time.Second, 20*time.Millisecond)
	d := s.conversation(t, "c-1", 200)
	assert.Equal(t, "讲讲", d.Messages[0].Text)
	assert.Equal(t, "已停止", d.Messages[1].Note)
	assert.Empty(t, d.Messages[1].Error)

	// The conversation is free again afterwards.
	conv2 := fake.Script(fake.Turn{Text: "好"})
	s.reg.SetConverser(llm.RoleAgent, s.guard.WrapConverser(llm.RoleAgent, conv2))
	s.ask(t, "c-1", "learn", "继续", nil)
}

func TestAgentHistory_OneAnswerAtATimePerConversation(t *testing.T) {
	s := newServer(t)
	conv := fake.Script(fake.Turn{Text: "a"}, fake.Turn{Text: "b"})
	release := conv.Block()
	enableAgent(t, s, conv)
	s.guard.SetLimits(llm.Limits{MaxConcurrency: 4})

	done := make(chan struct{})
	go func() {
		defer close(done)
		resp := s.agentReq(t, "POST", "/api/v1/agent/chat", appToken, storedBody("c-1", "learn", "第一问", nil))
		defer resp.Body.Close()
		readSSE(t, resp)
	}()
	require.Eventually(t, func() bool { return len(conv.Requests()) == 1 }, 5*time.Second, 10*time.Millisecond)

	resp := s.agentReq(t, "POST", "/api/v1/agent/chat", appToken, storedBody("c-1", "learn", "第二问", nil))
	assert.Equal(t, 409, resp.StatusCode, "a second question while the first is being answered")
	resp.Body.Close()
	resp = s.agentReq(t, "DELETE", "/api/v1/agent/conversations/c-1", appToken, "")
	assert.Equal(t, 409, resp.StatusCode, "nor can it be deleted under the answer")
	resp.Body.Close()

	// Another conversation is not held up.
	other := make(chan struct{})
	go func() {
		defer close(other)
		resp := s.agentReq(t, "POST", "/api/v1/agent/chat", appToken, storedBody("c-2", "learn", "别的", nil))
		defer resp.Body.Close()
		assert.Equal(t, 200, resp.StatusCode)
		readSSE(t, resp)
	}()
	require.Eventually(t, func() bool { return len(conv.Requests()) == 2 }, 5*time.Second, 10*time.Millisecond)
	release()
	<-done
	<-other
	assert.Len(t, s.conversation(t, "c-1", 200).Messages, 2, "the refused question left nothing behind")
}

func TestAgentHistory_ListPagesFiltersAndRenames(t *testing.T) {
	s := newServer(t)
	enableAgent(t, s, fake.NewConverser(func(int, llm.ChatRequest) fake.Turn { return fake.Turn{Text: "好"} }))
	s.guard.SetLimits(llm.Limits{MaxConcurrency: 4})
	for i, mode := range []string{"learn", "create", "learn"} {
		s.ask(t, fmt.Sprintf("c-%d", i), mode, fmt.Sprintf("问题 %d", i), nil)
		time.Sleep(3 * time.Millisecond) // updated_at is in milliseconds
	}

	first := s.conversations(t, "?limit=2")
	require.Len(t, first.Items, 2)
	assert.True(t, first.HasMore)
	assert.Equal(t, []string{"c-2", "c-1"}, []string{first.Items[0].ID, first.Items[1].ID}, "newest first")
	rest := s.conversations(t, fmt.Sprintf("?limit=2&before=%d", first.Items[1].UpdatedAt))
	require.Len(t, rest.Items, 1)
	assert.False(t, rest.HasMore)
	assert.Equal(t, "c-0", rest.Items[0].ID)

	create := s.conversations(t, "?mode=create")
	require.Len(t, create.Items, 1)
	assert.Equal(t, "c-1", create.Items[0].ID)
	resp := s.agentReq(t, "GET", "/api/v1/agent/conversations?mode=bogus", appToken, "")
	assert.Equal(t, 400, resp.StatusCode)
	resp.Body.Close()

	// Speaking in an old conversation brings it to the top.
	s.ask(t, "c-0", "learn", "再问", nil)
	assert.Equal(t, "c-0", s.conversations(t, "").Items[0].ID)

	resp = s.agentReq(t, "PATCH", "/api/v1/agent/conversations/c-0", appToken, `{"title":"  死锁\n复习 "}`)
	assert.Equal(t, 204, resp.StatusCode)
	resp.Body.Close()
	assert.Equal(t, "死锁 复习", s.conversation(t, "c-0", 200).Title)
	for _, c := range []struct{ id, body string }{{"c-0", `{"title":"  "}`}, {"c-0", `nope`}} {
		resp = s.agentReq(t, "PATCH", "/api/v1/agent/conversations/"+c.id, appToken, c.body)
		assert.Equal(t, 400, resp.StatusCode, c.body)
		resp.Body.Close()
	}
	resp = s.agentReq(t, "PATCH", "/api/v1/agent/conversations/nope", appToken, `{"title":"x"}`)
	assert.Equal(t, 404, resp.StatusCode)
	resp.Body.Close()
}

func TestAgentHistory_ReopenedDraftsShowWhatBecameOfThem_AndDeletingDiscardsTheRest(t *testing.T) {
	var lesson string
	conv := fake.NewConverser(func(n int, _ llm.ChatRequest) fake.Turn {
		if n == 0 {
			return fake.Turn{Calls: []fake.Call{proposeCall(lesson,
				q1("关于读写锁的并发特性，下列哪项描述是正确的？", 0),
				q1("在多读少写的场景中，读写锁相比互斥锁的优势是什么？", 0),
				q1("读写锁里写者对资源的访问有什么要求？", 0))}}
		}
		return fake.Turn{Text: "出了 3 道题。"}
	})
	s, lessonID := createFixture(t, conv)
	lesson = lessonID

	s.ask(t, "c-1", "create", "出 3 道题", map[string]any{"context": map[string]any{"lesson_id": lessonID}})
	ids := s.draftIDs(t, "c-1")
	require.Len(t, ids, 3)
	keep, drop, wait := ids[0], ids[1], ids[2]
	for path, want := range map[string]int{keep + "/accept": 200, drop + "/discard": 200} {
		resp := s.agentReq(t, "POST", "/api/v1/agent/drafts/"+path, appToken, "")
		require.Equal(t, want, resp.StatusCode)
		resp.Body.Close()
	}

	// Reopened, every card shows where it stands.
	d := s.conversation(t, "c-1", 200)
	phases := map[string]string{}
	for _, m := range d.Messages {
		for _, dr := range m.Drafts {
			phases[dr.DraftID] = dr.Phase
			assert.NotEmpty(t, dr.Stem)
		}
	}
	assert.Equal(t, map[string]string{keep: "accepted", drop: "discarded", wait: "pending"}, phases)
	list := s.conversations(t, "")
	require.Len(t, list.Items, 1)
	assert.Equal(t, 1, list.Items[0].PendingDrafts)
	assert.Equal(t, "create", list.Items[0].Mode)

	// Deleting throws away the one nobody decided on; the accepted question stays in the review queue.
	resp := s.agentReq(t, "DELETE", "/api/v1/agent/conversations/c-1", appToken, "")
	require.Equal(t, 204, resp.StatusCode)
	resp.Body.Close()
	s.conversation(t, "c-1", 404)
	assert.Empty(t, s.conversations(t, "").Items)
	assert.Empty(t, s.draftIDs(t, "c-1"))
	var q struct{ Status string }
	s.do(t, "GET", "/admin/questions/"+keep, "", 200, &q)
	assert.Equal(t, "needs_review", q.Status)
	s.do(t, "GET", "/admin/questions/"+wait, "", 200, &q)
	assert.Equal(t, "rejected", q.Status)

	resp = s.agentReq(t, "DELETE", "/api/v1/agent/conversations/c-1", appToken, "")
	assert.Equal(t, 404, resp.StatusCode)
	resp.Body.Close()
}

func TestAgentHistory_ContextIsKeptWithTheConversation(t *testing.T) {
	s := newServer(t)
	s.publishOne(t)
	var banks []struct{ ID string }
	s.do(t, "GET", "/api/v1/banks", "", 200, &banks)
	enableAgent(t, s, fake.NewConverser(func(int, llm.ChatRequest) fake.Turn { return fake.Turn{Text: "好"} }))
	s.guard.SetLimits(llm.Limits{MaxConcurrency: 4})

	s.ask(t, "c-1", "learn", "问", map[string]any{"context": map[string]any{"bank_id": banks[0].ID}})
	s.ask(t, "c-1", "learn", "再问", map[string]any{"context": map[string]any{}})
	d := s.conversation(t, "c-1", 200)
	assert.Equal(t, banks[0].ID, d.BankID, "what the learner was looking at when it began")
	assert.Equal(t, banks[0].ID, s.conversations(t, "").Items[0].BankID)
}
