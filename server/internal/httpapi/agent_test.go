package httpapi_test

import (
	"bufio"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/chlu-ux/quizmind/server/internal/llm"
	"github.com/chlu-ux/quizmind/server/internal/llm/fake"
)

const appToken = "1234"

// enableAgent sets the access token and binds a scripted model to the agent role.
func enableAgent(t *testing.T, s *server, conv *fake.Converser) {
	t.Helper()
	s.do(t, "PUT", "/admin/ai", `{"enabled":false,"app_token":"`+appToken+`"}`, 200, nil)
	s.reg.SetConverser(llm.RoleAgent, s.guard.WrapConverser(llm.RoleAgent, conv))
}

func (s *server) agentReq(t *testing.T, method, path, token, body string) *http.Response {
	t.Helper()
	r, err := http.NewRequest(method, s.ts.URL+path, strings.NewReader(body))
	require.NoError(t, err)
	r.Header.Set("Content-Type", "application/json")
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(r)
	require.NoError(t, err)
	return resp
}

type sseEvent struct {
	Name string
	Data map[string]any
}

// readSSE reads a stream to its end, also returning the comment lines seen.
func readSSE(t *testing.T, resp *http.Response) (events []sseEvent, comments []string) {
	t.Helper()
	sc := bufio.NewScanner(resp.Body)
	var cur sseEvent
	for sc.Scan() {
		line := sc.Text()
		switch {
		case strings.HasPrefix(line, ":"):
			comments = append(comments, line)
		case strings.HasPrefix(line, "event: "):
			cur = sseEvent{Name: strings.TrimPrefix(line, "event: ")}
		case strings.HasPrefix(line, "data: "):
			require.NoError(t, json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &cur.Data))
			events = append(events, cur)
		}
	}
	return events, comments
}

func chatBody(msg string) string {
	b, _ := json.Marshal(map[string]any{"device_id": "dev-1", "messages": []map[string]string{{"role": "user", "content": msg}}})
	return string(b)
}

func TestAgentAccess(t *testing.T) {
	s := newServer(t)

	// No access token has been set: nobody may use the assistant.
	for _, path := range []string{"/api/v1/agent/status"} {
		resp := s.agentReq(t, "GET", path, "anything", "")
		assert.Equal(t, 401, resp.StatusCode)
		resp.Body.Close()
	}
	resp := s.agentReq(t, "POST", "/api/v1/agent/chat", "", chatBody("hi"))
	assert.Equal(t, 401, resp.StatusCode)
	resp.Body.Close()

	// Token set but no model bound to the agent role: 404, so apps hide their entry points.
	s.do(t, "PUT", "/admin/ai", `{"enabled":false,"app_token":"`+appToken+`"}`, 200, nil)
	for _, c := range []struct{ method, path, body string }{
		{"GET", "/api/v1/agent/status", ""}, {"POST", "/api/v1/agent/chat", chatBody("hi")},
	} {
		resp := s.agentReq(t, c.method, c.path, appToken, c.body)
		assert.Equal(t, 404, resp.StatusCode, c.path)
		resp.Body.Close()
	}

	enableAgent(t, s, fake.Script())
	resp = s.agentReq(t, "GET", "/api/v1/agent/status", "wrong", "")
	assert.Equal(t, 401, resp.StatusCode)
	resp.Body.Close()
	resp = s.agentReq(t, "GET", "/api/v1/agent/status", appToken, "")
	defer resp.Body.Close()
	require.Equal(t, 200, resp.StatusCode)
	var st struct {
		Available bool
		Model     string
		Verified  bool
	}
	require.NoError(t, json.NewDecoder(resp.Body).Decode(&st))
	assert.True(t, st.Available)
	assert.Equal(t, "fake-model", st.Model)
	assert.False(t, st.Verified, "no validator bound")
}

func TestAgentChatStreamsAnAnswerAndRecordsUsage(t *testing.T) {
	s := newServer(t)
	s.publishOne(t)
	var lessons lessonsPage
	s.do(t, "GET", "/api/v1/lessons", "", 200, &lessons)
	lessonID := lessons.Items[0].ID

	conv := fake.Script(
		fake.Turn{Text: "我查一下。", Calls: []fake.Call{{Name: "search_lessons", Input: `{"query":"读写锁"}`}}, Usage: llm.Usage{InputTokens: 100, OutputTokens: 10}},
		fake.Turn{Text: "读写锁见[这一节](lesson:" + lessonID + ")，别信[假的](lesson:FAKE)。", Usage: llm.Usage{InputTokens: 200, OutputTokens: 30, CachedTokens: 50}},
	)
	enableAgent(t, s, conv)

	resp := s.agentReq(t, "POST", "/api/v1/agent/chat", appToken, chatBody("什么是读写锁"))
	defer resp.Body.Close()
	require.Equal(t, 200, resp.StatusCode)
	assert.Equal(t, "text/event-stream", resp.Header.Get("Content-Type"))
	events, _ := readSSE(t, resp)

	var names []string
	var text strings.Builder
	for _, e := range events {
		if e.Name == "delta" {
			text.WriteString(e.Data["text"].(string))
			if len(names) == 0 || names[len(names)-1] != "delta" {
				names = append(names, "delta")
			}
			continue
		}
		names = append(names, e.Name)
	}
	assert.Equal(t, []string{"start", "delta", "tool", "tool", "delta", "done"}, names)
	assert.Equal(t, "我查一下。读写锁见[这一节](lesson:"+lessonID+")，别信假的。", text.String())

	convID := events[0].Data["conversation_id"].(string)
	assert.NotEmpty(t, convID, "the server hands out a conversation id")
	done := events[len(events)-1]
	assert.Equal(t, "end_turn", done.Data["stop"])
	assert.EqualValues(t, 300, done.Data["usage"].(map[string]any)["input"])

	// Each model turn is its own row in the call log, tied to the conversation and the device.
	var calls struct {
		Items []struct {
			Role        string
			Source      string
			DeviceID    string `json:"device_id"`
			QuestionID  string `json:"question_id"` // the log's reference column: the conversation
			InputTokens int64  `json:"input_tokens"`
		}
	}
	s.do(t, "GET", "/admin/usage/calls?role=agent", "", 200, &calls)
	require.Len(t, calls.Items, 2)
	for _, c := range calls.Items {
		assert.Equal(t, "server", c.Source)
		assert.Equal(t, "dev-1", c.DeviceID)
		assert.Equal(t, convID, c.QuestionID)
	}
}

func TestAgentChatValidation(t *testing.T) {
	s := newServer(t)
	s.publishOne(t)
	enableAgent(t, s, fake.Script())

	long := strings.Repeat("长", 24001)
	cases := map[string]string{
		"no messages":            `{"messages":[]}`,
		"last is assistant":      `{"messages":[{"role":"user","content":"a"},{"role":"assistant","content":"b"}]}`,
		"first is assistant":     `{"messages":[{"role":"assistant","content":"a"},{"role":"user","content":"b"}]}`,
		"roles do not alternate": `{"messages":[{"role":"user","content":"a"},{"role":"user","content":"b"}]}`,
		"empty content":          `{"messages":[{"role":"user","content":"  "}]}`,
		"bad role":               `{"messages":[{"role":"system","content":"a"}]}`,
		"too long":               `{"messages":[{"role":"user","content":"` + long + `"}]}`,
		"unknown mode":           `{"mode":"x","messages":[{"role":"user","content":"a"}]}`,
		"unknown lesson":         `{"context":{"lesson_id":"nope"},"messages":[{"role":"user","content":"a"}]}`,
		"unknown question":       `{"context":{"question":{"id":"nope"}},"messages":[{"role":"user","content":"a"}]}`,
		"unknown bank":           `{"context":{"bank_id":"nope"},"messages":[{"role":"user","content":"a"}]}`,
		"not json":               `{`,
	}
	for name, body := range cases {
		resp := s.agentReq(t, "POST", "/api/v1/agent/chat", appToken, body)
		assert.Equal(t, 400, resp.StatusCode, name)
		resp.Body.Close()
	}
}

func TestAgentChatLimitsConversationsPerDevice(t *testing.T) {
	s := newServer(t)
	conv := fake.Script(fake.Turn{Text: "a"}, fake.Turn{Text: "b"}, fake.Turn{Text: "c"})
	release := conv.Block()
	s.guard.SetLimits(llm.Limits{MaxConcurrency: 10}) // the test server allows one model call at a time
	enableAgent(t, s, conv)

	var wg sync.WaitGroup
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			resp := s.agentReq(t, "POST", "/api/v1/agent/chat", appToken, chatBody("hi"))
			defer resp.Body.Close()
			readSSE(t, resp)
		}()
	}
	require.Eventually(t, func() bool { return len(conv.Requests()) == 2 }, 5*time.Second, 10*time.Millisecond)

	resp := s.agentReq(t, "POST", "/api/v1/agent/chat", appToken, chatBody("hi"))
	assert.Equal(t, 429, resp.StatusCode, "a third conversation from the same device")
	resp.Body.Close()

	other := `{"device_id":"dev-2","messages":[{"role":"user","content":"hi"}]}`
	var otherDone sync.WaitGroup
	otherDone.Add(1)
	go func() {
		defer otherDone.Done()
		resp := s.agentReq(t, "POST", "/api/v1/agent/chat", appToken, other)
		defer resp.Body.Close()
		assert.Equal(t, 200, resp.StatusCode, "another device is not affected")
		readSSE(t, resp)
	}()
	require.Eventually(t, func() bool { return len(conv.Requests()) == 3 }, 5*time.Second, 10*time.Millisecond)

	release()
	wg.Wait()
	otherDone.Wait()

	// The slots are free again.
	resp = s.agentReq(t, "POST", "/api/v1/agent/chat", appToken, chatBody("hi"))
	defer resp.Body.Close()
	assert.Equal(t, 200, resp.StatusCode)
}

// gateway is a stand-in for an Anthropic-protocol endpoint: it streams, calls the "echo" tool when
// it is offered one, and remembers whether thinking blocks came back with the tool result.
type gateway struct {
	noisy bool
	// rejectResults refuses any request that carries a tool result, as gateways that cannot do multi-turn tool use do.
	rejectResults bool

	mu           sync.Mutex
	thinkingBack bool
	requests     int
}

func (g *gateway) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Stream   bool             `json:"stream"`
		Tools    []map[string]any `json:"tools"`
		Messages []struct {
			Role    string
			Content []map[string]any
		}
	}
	_ = json.NewDecoder(r.Body).Decode(&req)
	g.mu.Lock()
	g.requests++
	g.mu.Unlock()

	hasResult := false
	for _, m := range req.Messages {
		for _, b := range m.Content {
			switch b["type"] {
			case "tool_result":
				hasResult = true
			case "thinking":
				g.mu.Lock()
				g.thinkingBack = b["signature"] == "sig-1"
				g.mu.Unlock()
			}
		}
	}
	if hasResult && g.rejectResults {
		w.WriteHeader(400)
		_, _ = w.Write([]byte(`{"type":"error","error":{"type":"invalid_request_error","message":"tool_result not supported"}}`))
		return
	}

	if !req.Stream { // the plain request the model test starts with
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"msg_0","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"pong"}],` +
			`"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":5,"output_tokens":1}}`))
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	send := func(typ string, data any) {
		b, _ := json.Marshal(data)
		_, _ = w.Write([]byte("event: " + typ + "\ndata: " + string(b) + "\n\n"))
	}
	m := func(kv ...any) map[string]any {
		out := map[string]any{}
		for i := 0; i < len(kv); i += 2 {
			out[kv[i].(string)] = kv[i+1]
		}
		return out
	}
	send("message_start", m("type", "message_start", "message", m("id", "msg_1", "type", "message", "role", "assistant", "model", "m",
		"content", []any{}, "stop_reason", nil, "stop_sequence", nil,
		"usage", m("input_tokens", 10, "output_tokens", 0, "cache_creation_input_tokens", 0, "cache_read_input_tokens", 0))))
	idx := 0
	text := func(s string) {
		send("content_block_start", m("type", "content_block_start", "index", idx, "content_block", m("type", "text", "text", "")))
		send("content_block_delta", m("type", "content_block_delta", "index", idx, "delta", m("type", "text_delta", "text", s)))
		send("content_block_stop", m("type", "content_block_stop", "index", idx))
		idx++
	}
	stop := "end_turn"
	switch {
	case len(req.Tools) > 0 && !hasResult:
		send("content_block_start", m("type", "content_block_start", "index", 0, "content_block", m("type", "thinking", "thinking", "", "signature", "")))
		send("content_block_delta", m("type", "content_block_delta", "index", 0, "delta", m("type", "thinking_delta", "thinking", "call it")))
		send("content_block_delta", m("type", "content_block_delta", "index", 0, "delta", m("type", "signature_delta", "signature", "sig-1")))
		send("content_block_stop", m("type", "content_block_stop", "index", 0))
		send("content_block_start", m("type", "content_block_start", "index", 1, "content_block", m("type", "tool_use", "id", "call_1", "name", "echo", "input", m())))
		send("content_block_delta", m("type", "content_block_delta", "index", 1, "delta", m("type", "input_json_delta", "partial_json", `{"text":"ok"}`)))
		send("content_block_stop", m("type", "content_block_stop", "index", 1))
		stop = "tool_use"
	case g.noisy:
		text("pong<ds_safety>[用户未成年]否</ds_safety>Safe")
	default:
		text("pong")
	}
	send("message_delta", m("type", "message_delta", "delta", m("stop_reason", stop, "stop_sequence", nil), "usage", m("output_tokens", 5)))
	send("message_stop", m("type", "message_stop"))
}

type testReport struct {
	OK     bool
	Error  string
	Checks []struct {
		Name   string
		OK     bool
		Detail string
	}
}

// bindAgentModel adds the gateway as a provider and model, binds it to the agent role, and returns the model id.
func bindAgentModel(t *testing.T, s *server, gw *gateway) string {
	t.Helper()
	srv := httptest.NewServer(gw)
	t.Cleanup(srv.Close)
	var provider, model struct{ ID string }
	s.do(t, "POST", "/admin/llm/providers", `{"name":"Gateway","protocol":"anthropic","base_url":"`+srv.URL+`","api_key":"sk-gateway-1"}`, 201, &provider)
	s.do(t, "POST", "/admin/llm/models", `{"provider_id":"`+provider.ID+`","model":"gw-model"}`, 201, &model)
	s.do(t, "PUT", "/admin/llm/roles", `{"agent":"`+model.ID+`"}`, 200, nil)
	return model.ID
}

func TestAgentModelCompatibilityProbe(t *testing.T) {
	t.Run("a good gateway passes", func(t *testing.T) {
		s := newServer(t)
		gw := &gateway{}
		id := bindAgentModel(t, s, gw)
		var rep testReport
		s.do(t, "POST", "/admin/llm/models/"+id+"/test", "", 200, &rep)
		assert.True(t, rep.OK, rep.Error)
		var names []string
		for _, c := range rep.Checks {
			assert.True(t, c.OK, c.Name+": "+c.Detail)
			names = append(names, c.Name)
		}
		assert.Equal(t, []string{"流式输出", "工具调用", "多轮工具往返", "正文干净"}, names)
		assert.True(t, gw.thinkingBack, "the thinking block was sent back with the tool result")
	})

	t.Run("a gateway that cannot continue after a tool result fails", func(t *testing.T) {
		s := newServer(t)
		id := bindAgentModel(t, s, &gateway{rejectResults: true})
		var rep testReport
		s.do(t, "POST", "/admin/llm/models/"+id+"/test", "", 200, &rep)
		assert.False(t, rep.OK)
		assert.Contains(t, rep.Error, "多轮工具往返")
		require.Len(t, rep.Checks, 4)
		assert.True(t, rep.Checks[1].OK)
		assert.False(t, rep.Checks[2].OK)
		assert.Contains(t, rep.Checks[2].Detail, "tool_result not supported")
	})

	t.Run("leaked markers are a warning, not a failure", func(t *testing.T) {
		s := newServer(t)
		id := bindAgentModel(t, s, &gateway{noisy: true})
		var rep testReport
		s.do(t, "POST", "/admin/llm/models/"+id+"/test", "", 200, &rep)
		assert.True(t, rep.OK, rep.Error)
		last := rep.Checks[len(rep.Checks)-1]
		assert.Equal(t, "正文干净", last.Name)
		assert.False(t, last.OK)
		assert.Contains(t, last.Detail, "ds_safety")
	})

	t.Run("an unreachable endpoint fails the first check", func(t *testing.T) {
		s := newServer(t)
		var provider, model struct{ ID string }
		s.do(t, "POST", "/admin/llm/providers", `{"name":"Dead","protocol":"anthropic","base_url":"http://127.0.0.1:1","api_key":"sk-dead-1"}`, 201, &provider)
		s.do(t, "POST", "/admin/llm/models", `{"provider_id":"`+provider.ID+`","model":"m"}`, 201, &model)
		s.do(t, "PUT", "/admin/llm/roles", `{"agent":"`+model.ID+`"}`, 200, nil)
		var rep testReport
		s.do(t, "POST", "/admin/llm/models/"+model.ID+"/test", "", 200, &rep)
		assert.False(t, rep.OK)
		assert.NotContains(t, rep.Error, "sk-dead-1")
	})

	t.Run("a model not bound to the agent role is only pinged", func(t *testing.T) {
		s := newServer(t)
		gw := &gateway{}
		id := bindAgentModel(t, s, gw)
		s.do(t, "PUT", "/admin/llm/roles", `{}`, 200, nil)
		var rep testReport
		s.do(t, "POST", "/admin/llm/models/"+id+"/test", "", 200, &rep)
		assert.True(t, rep.OK)
		assert.Empty(t, rep.Checks)
	})
}

func TestAgentEndToEndThroughTheRealClient(t *testing.T) {
	s := newServer(t)
	s.guard.SetLimits(llm.Limits{MaxConcurrency: 4})
	gw := &gateway{}
	bindAgentModel(t, s, gw)
	s.do(t, "PUT", "/admin/ai", `{"enabled":false,"app_token":"`+appToken+`"}`, 200, nil)

	// Saving the role made the assistant available without a restart.
	resp := s.agentReq(t, "GET", "/api/v1/agent/status", appToken, "")
	require.Equal(t, 200, resp.StatusCode)
	resp.Body.Close()

	// The gateway always calls "echo" when offered tools; the assistant has none by that name, so
	// the call comes back as an error result and the next turn answers.
	resp = s.agentReq(t, "POST", "/api/v1/agent/chat", appToken, chatBody("hi"))
	defer resp.Body.Close()
	require.Equal(t, 200, resp.StatusCode)
	events, _ := readSSE(t, resp)
	var names []string
	for _, e := range events {
		names = append(names, e.Name)
	}
	assert.Equal(t, []string{"start", "tool", "tool", "delta", "done"}, names)
	assert.Equal(t, "error", events[2].Data["status"], "an unknown tool is reported, not fatal")
	assert.Equal(t, "end_turn", events[len(events)-1].Data["stop"])
	assert.True(t, gw.thinkingBack, "the thinking block survived the round trip through the loop")
}
