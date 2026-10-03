package httpapi_test

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/chlu-ux/quizmind/server/internal/config"
	"github.com/chlu-ux/quizmind/server/internal/db"
	"github.com/chlu-ux/quizmind/server/internal/events"
	"github.com/chlu-ux/quizmind/server/internal/httpapi"
	"github.com/chlu-ux/quizmind/server/internal/jobs"
	"github.com/chlu-ux/quizmind/server/internal/llm"
	"github.com/chlu-ux/quizmind/server/internal/llm/fake"
	"github.com/chlu-ux/quizmind/server/internal/service"
)

const token = "test-token"

const doc = "# 并发\n\n## 读写锁\n\n读写锁允许多个读者同时持有锁，但写者必须独占整个资源。这是读写锁最核心的特点之一。在读多写少的场景下，读写锁能够显著提高并发性能，因为读者之间不需要互相等待。\n"

type server struct {
	ts   *httptest.Server
	bank string
}

func newServer(t *testing.T) *server {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "app.db"))
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })

	cfg := config.Default()
	cfg.Pipeline.ChunkMinChars, cfg.Pipeline.ChunkMaxChars = 40, 600

	fk := fake.New(func(req llm.JSONRequest) (any, error) {
		quote := "读写锁允许多个读者同时持有锁，但写者必须独占整个资源。"
		return map[string]any{"questions": []map[string]any{{
			"type": "single", "stem": "关于读写锁，下列哪项描述是正确的？",
			"options":      []string{"多个读者可同时持有锁", "同一时刻只能有一个读者", "写者可与读者并行", "读写锁禁止写者"},
			"answer_index": 0, "explanation": "见原文", "difficulty": 2, "tags": []string{"锁"}, "source_quote": quote,
		}}}, nil
	})
	guard := llm.NewGuard(llm.Limits{MaxConcurrency: 1}, service.LLMRecorder{DB: d})
	reg := llm.NewRegistry()
	reg.Set(llm.RoleGenerator, guard.Wrap(llm.RoleGenerator, fk))

	hub := events.NewHub()
	q := jobs.NewQueue(d)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	svc := service.New(d, cfg, reg, q, hub, log)
	runner := jobs.NewRunner(d, q, 1, log, hub)
	svc.RegisterHandlers(runner)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { runner.Run(ctx); close(done) }()
	t.Cleanup(func() { cancel(); <-done })

	static := fstest.MapFS{"index.html": {Data: []byte("<html>admin ui</html>")}, "app.js": {Data: []byte("console.log(1)")},
		"m/index.html": {Data: []byte("<html>phone app</html>")}, "m/assets/a.js": {Data: []byte("console.log(2)")}}
	ts := httptest.NewServer(httpapi.New(svc, hub, token, static, log))
	t.Cleanup(ts.Close)

	s := &server{ts: ts}
	var bank struct{ ID string }
	s.do(t, "POST", "/admin/banks", `{"title":"题库","description":""}`, 201, &bank)
	s.bank = bank.ID
	return s
}

func (s *server) req(t *testing.T, method, path string, body io.Reader, contentType string, auth bool) *http.Response {
	t.Helper()
	r, err := http.NewRequest(method, s.ts.URL+path, body)
	require.NoError(t, err)
	if contentType != "" {
		r.Header.Set("Content-Type", contentType)
	}
	if auth {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(r)
	require.NoError(t, err)
	return resp
}

func (s *server) do(t *testing.T, method, path, body string, wantStatus int, out any) {
	t.Helper()
	var rd io.Reader
	if body != "" {
		rd = strings.NewReader(body)
	}
	resp := s.req(t, method, path, rd, "application/json", true)
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	require.Equal(t, wantStatus, resp.StatusCode, "%s %s -> %s", method, path, raw)
	if out != nil {
		require.NoError(t, json.Unmarshal(raw, out), string(raw))
	}
}

func (s *server) upload(t *testing.T, filename, content string) *http.Response {
	t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	require.NoError(t, mw.WriteField("bank_id", s.bank))
	fw, err := mw.CreateFormFile("file", filename)
	require.NoError(t, err)
	_, _ = fw.Write([]byte(content))
	require.NoError(t, mw.Close())
	return s.req(t, "POST", "/admin/documents", &buf, mw.FormDataContentType(), true)
}

func TestAuth(t *testing.T) {
	s := newServer(t)
	resp := s.req(t, "GET", "/admin/banks", nil, "", false)
	resp.Body.Close()
	assert.Equal(t, 401, resp.StatusCode)

	r, _ := http.NewRequest("GET", s.ts.URL+"/admin/banks", nil)
	r.Header.Set("Authorization", "Bearer wrong")
	resp, err := http.DefaultClient.Do(r)
	require.NoError(t, err)
	resp.Body.Close()
	assert.Equal(t, 401, resp.StatusCode)

	resp = s.req(t, "GET", "/healthz", nil, "", false)
	resp.Body.Close()
	assert.Equal(t, 200, resp.StatusCode, "healthz is open")

	// The query token works only for the SSE endpoint.
	resp, err = http.Get(s.ts.URL + "/admin/banks?access_token=" + token)
	require.NoError(t, err)
	resp.Body.Close()
	assert.Equal(t, 401, resp.StatusCode)
}

func TestUploadReviewFlow(t *testing.T) {
	s := newServer(t)

	resp := s.upload(t, "notes.md", doc)
	require.Equal(t, 201, resp.StatusCode)
	var res struct {
		Document struct{ ID, Status string }
		Created  bool
	}
	require.NoError(t, json.NewDecoder(resp.Body).Decode(&res))
	resp.Body.Close()
	require.True(t, res.Created)

	require.Eventually(t, func() bool {
		var d struct{ Status string }
		s.do(t, "GET", "/admin/documents/"+res.Document.ID, "", 200, &d)
		return d.Status == "review"
	}, 10*time.Second, 25*time.Millisecond)

	var page struct {
		Items []struct{ ID, Status, Stem string }
		Total int
	}
	s.do(t, "GET", "/admin/questions?status=needs_review&document_id="+res.Document.ID, "", 200, &page)
	require.Equal(t, 1, page.Total)

	var detail struct {
		ChunkText   string `json:"chunk_text"`
		SourceQuote string `json:"source_quote"`
		HeadingPath string `json:"heading_path"`
	}
	s.do(t, "GET", "/admin/questions/"+page.Items[0].ID, "", 200, &detail)
	assert.Contains(t, detail.ChunkText, detail.SourceQuote, "review page can highlight the quote in the source")
	assert.Equal(t, "并发 > 读写锁", detail.HeadingPath)

	var pub struct {
		Status  string
		SyncSeq *int64 `json:"sync_seq"`
	}
	s.do(t, "POST", "/admin/questions/"+page.Items[0].ID+"/approve", "", 200, &pub)
	assert.Equal(t, "published", pub.Status)
	require.NotNil(t, pub.SyncSeq)

	var edited struct{ Stem string }
	s.do(t, "PATCH", "/admin/questions/"+page.Items[0].ID, `{"stem":"关于读写锁，下列哪个说法是对的？"}`, 200, &edited)
	assert.Equal(t, "关于读写锁，下列哪个说法是对的？", edited.Stem)
	s.do(t, "PATCH", "/admin/questions/"+page.Items[0].ID, `{"options":["a","a","b","c"]}`, 400, nil)

	var banks []struct {
		QuestionCounts map[string]int64 `json:"question_counts"`
	}
	s.do(t, "GET", "/admin/banks", "", 200, &banks)
	assert.EqualValues(t, 1, banks[0].QuestionCounts["published"])

	var usage []struct {
		Calls       int64
		InputTokens int64 `json:"input_tokens"`
	}
	s.do(t, "GET", "/admin/usage", "", 200, &usage)
	require.Len(t, usage, 1)
	assert.EqualValues(t, 1, usage[0].Calls, "LLM call was logged")

	var jobs []struct{ Type, Status string }
	s.do(t, "GET", "/admin/jobs?document_id="+res.Document.ID, "", 200, &jobs)
	assert.Len(t, jobs, 2)

	// Same bytes again: 200 + unchanged, no new work.
	resp = s.upload(t, "notes.md", doc)
	assert.Equal(t, 200, resp.StatusCode)
	var again struct{ Unchanged bool }
	require.NoError(t, json.NewDecoder(resp.Body).Decode(&again))
	resp.Body.Close()
	assert.True(t, again.Unchanged)
}

func TestUploadErrorsAndNotFound(t *testing.T) {
	s := newServer(t)
	resp := s.upload(t, "notes.txt", doc)
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	assert.Equal(t, 400, resp.StatusCode)
	assert.Contains(t, string(body), ".md")

	s.do(t, "GET", "/admin/questions/nope", "", 404, nil)
	s.do(t, "GET", "/admin/documents/nope", "", 404, nil)
	s.do(t, "POST", "/admin/questions/bulk", `{"action":"explode","ids":["x"]}`, 400, nil)
	s.do(t, "POST", "/admin/banks", `{"title":""}`, 400, nil)
	s.do(t, "POST", "/admin/banks", `not json`, 400, nil)
	s.do(t, "POST", "/admin/jobs/nope/retry", "", 404, nil)

	// multipart without bank
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	fw, _ := mw.CreateFormFile("file", "a.md")
	_, _ = fw.Write([]byte(doc))
	mw.Close()
	resp = s.req(t, "POST", "/admin/documents", &buf, mw.FormDataContentType(), true)
	resp.Body.Close()
	assert.Equal(t, 404, resp.StatusCode, "unknown bank")
}

func TestStaticUIAndSPAFallback(t *testing.T) {
	s := newServer(t)
	get := func(p string) (int, string) {
		resp, err := http.Get(s.ts.URL + p)
		require.NoError(t, err)
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(b)
	}
	code, body := get("/")
	assert.Equal(t, 200, code)
	assert.Contains(t, body, "admin ui")
	code, body = get("/app.js")
	assert.Equal(t, 200, code)
	assert.Contains(t, body, "console.log")
	code, body = get("/some/client/route")
	assert.Equal(t, 200, code, "unknown UI paths fall back to index.html")
	assert.Contains(t, body, "admin ui")

	// The phone app is served under /m/ with its own fallback.
	code, body = get("/m/")
	assert.Equal(t, 200, code)
	assert.Contains(t, body, "phone app")
	code, body = get("/m/assets/a.js")
	assert.Equal(t, 200, code)
	assert.Contains(t, body, "console.log(2)")
	code, body = get("/m/whatever")
	assert.Equal(t, 200, code)
	assert.Contains(t, body, "phone app")
	noRedirect := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	rr, err := noRedirect.Get(s.ts.URL + "/m")
	require.NoError(t, err)
	rr.Body.Close()
	assert.Equal(t, 301, rr.StatusCode)
	assert.Equal(t, "/m/", rr.Header.Get("Location"))

	code, _ = get("/admin/nothing-here")
	assert.Equal(t, 401, code, "unauthenticated API paths are refused, never served the UI")
	resp := s.req(t, "GET", "/admin/nothing-here", nil, "", true)
	resp.Body.Close()
	assert.Equal(t, 404, resp.StatusCode, "authenticated unknown API paths 404 instead of falling back to the UI")
}

func TestSSEStreamsProgress(t *testing.T) {
	s := newServer(t)
	r, _ := http.NewRequest("GET", s.ts.URL+"/admin/events?access_token="+token, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	resp, err := http.DefaultClient.Do(r.WithContext(ctx))
	require.NoError(t, err)
	defer resp.Body.Close()
	require.Equal(t, "text/event-stream", resp.Header.Get("Content-Type"))

	lines := make(chan string, 64)
	go func() {
		sc := bufio.NewScanner(resp.Body)
		for sc.Scan() {
			lines <- sc.Text()
		}
		close(lines)
	}()
	require.Equal(t, ": connected", <-lines)

	up := s.upload(t, "x.md", doc)
	up.Body.Close()

	sawDocReview := false
	for !sawDocReview {
		select {
		case l, ok := <-lines:
			if !ok {
				t.Fatal("stream closed early")
			}
			if strings.HasPrefix(l, "data:") && strings.Contains(l, `"type":"document"`) && strings.Contains(l, `"status":"review"`) {
				sawDocReview = true
			}
		case <-ctx.Done():
			t.Fatal("timed out waiting for the document to reach review over SSE")
		}
	}
}

func TestSSEEndsWhenHubCloses(t *testing.T) {
	d, err := db.Open(filepath.Join(t.TempDir(), "app.db"))
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	hub := events.NewHub()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	svc := service.New(d, config.Default(), llm.NewRegistry(), jobs.NewQueue(d), hub, log)
	ts := httptest.NewServer(httpapi.New(svc, hub, "", fstest.MapFS{"index.html": {Data: []byte("x")}}, log))
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/admin/events")
	require.NoError(t, err)
	defer resp.Body.Close()

	finished := make(chan struct{})
	go func() { _, _ = io.Copy(io.Discard, resp.Body); close(finished) }()
	time.Sleep(50 * time.Millisecond)
	hub.Close()
	select {
	case <-finished:
	case <-time.After(3 * time.Second):
		t.Fatal("SSE stream did not end after the hub closed; server shutdown would hang")
	}
}

// publishOne uploads the sample doc, waits for generation and approves its question.
func (s *server) publishOne(t *testing.T) string {
	t.Helper()
	resp := s.upload(t, "notes.md", doc)
	require.Equal(t, 201, resp.StatusCode)
	var res struct{ Document struct{ ID string } }
	require.NoError(t, json.NewDecoder(resp.Body).Decode(&res))
	resp.Body.Close()
	var page struct{ Items []struct{ ID string } }
	require.Eventually(t, func() bool {
		s.do(t, "GET", "/admin/questions?status=needs_review&document_id="+res.Document.ID, "", 200, &page)
		return len(page.Items) == 1
	}, 10*time.Second, 25*time.Millisecond)
	s.do(t, "POST", "/admin/questions/"+page.Items[0].ID+"/approve", "", 200, nil)
	return page.Items[0].ID
}

func TestAppSync(t *testing.T) {
	s := newServer(t)

	resp := s.req(t, "GET", "/api/v1/banks", nil, "", false)
	resp.Body.Close()
	assert.Equal(t, 200, resp.StatusCode, "the quiz API needs no token")

	qid := s.publishOne(t)

	var banks []struct {
		ID            string
		QuestionCount int64 `json:"question_count"`
	}
	s.do(t, "GET", "/api/v1/banks", "", 200, &banks)
	require.Len(t, banks, 1)
	assert.EqualValues(t, 1, banks[0].QuestionCount)

	type syncPage struct {
		Items []struct {
			ID      string
			Answer  []int
			Options []string
			SyncSeq int64 `json:"sync_seq"`
		}
		Deleted []string
		NextSeq int64 `json:"next_seq"`
		HasMore bool  `json:"has_more"`
	}
	var q1 syncPage
	s.do(t, "GET", "/api/v1/sync/questions?since=0", "", 200, &q1)
	require.Len(t, q1.Items, 1)
	assert.Equal(t, qid, q1.Items[0].ID)
	assert.Equal(t, []int{0}, q1.Items[0].Answer)
	assert.Len(t, q1.Items[0].Options, 4)
	assert.Empty(t, q1.Deleted)
	assert.False(t, q1.HasMore)
	assert.Equal(t, q1.Items[0].SyncSeq, q1.NextSeq)

	var q2 syncPage
	s.do(t, "GET", "/api/v1/sync/questions?since="+itoa(q1.NextSeq), "", 200, &q2)
	assert.Empty(t, q2.Items)
	assert.Equal(t, q1.NextSeq, q2.NextSeq, "an empty page keeps the cursor")

	// Attempts are idempotent and tolerate unknown questions.
	body := `[{"id":"A1","question_id":"` + qid + `","device_id":"d1","answer":[0],"is_correct":true,"duration_ms":1500,"answered_at":1000},
	          {"id":"A2","question_id":"nope","device_id":"d1","answer":[1],"is_correct":false,"answered_at":1001}]`
	var up struct{ Accepted, Ignored int }
	s.do(t, "POST", "/api/v1/sync/attempts", body, 200, &up)
	assert.Equal(t, 1, up.Accepted)
	assert.Equal(t, 1, up.Ignored)
	s.do(t, "POST", "/api/v1/sync/attempts", body, 200, &up)
	assert.Equal(t, 0, up.Accepted, "re-upload is a no-op")
	s.do(t, "POST", "/api/v1/sync/attempts", `[{"id":"","question_id":"x","device_id":"d","answered_at":1}]`, 400, nil)

	// A second device downloads the answer history by server sequence.
	type attemptsPage struct {
		Items []struct {
			ID         string
			QuestionID string `json:"question_id"`
			DeviceID   string `json:"device_id"`
			Answer     []int
			IsCorrect  bool   `json:"is_correct"`
			DurationMs *int64 `json:"duration_ms"`
			AnsweredAt int64  `json:"answered_at"`
		}
		NextSeq int64 `json:"next_seq"`
		HasMore bool  `json:"has_more"`
	}
	var at1 attemptsPage
	s.do(t, "GET", "/api/v1/sync/attempts?since=0", "", 200, &at1)
	require.Len(t, at1.Items, 1, "the attempt for an unknown question was never stored")
	assert.Equal(t, "A1", at1.Items[0].ID)
	assert.Equal(t, "d1", at1.Items[0].DeviceID)
	assert.Equal(t, []int{0}, at1.Items[0].Answer)
	assert.True(t, at1.Items[0].IsCorrect)
	assert.EqualValues(t, 1500, *at1.Items[0].DurationMs)
	assert.EqualValues(t, 1000, at1.Items[0].AnsweredAt)
	s.do(t, "POST", "/api/v1/sync/attempts", `[{"id":"A3","question_id":"`+qid+`","device_id":"d2","answer":[2],"is_correct":false,"answered_at":2000}]`, 200, &up)
	var at2 attemptsPage
	s.do(t, "GET", "/api/v1/sync/attempts?since="+itoa(at1.NextSeq), "", 200, &at2)
	require.Len(t, at2.Items, 1, "only what is new after the cursor")
	assert.Equal(t, "A3", at2.Items[0].ID)
	assert.Nil(t, at2.Items[0].DurationMs)
	var at3 attemptsPage
	s.do(t, "GET", "/api/v1/sync/attempts?since="+itoa(at2.NextSeq), "", 200, &at3)
	assert.Empty(t, at3.Items)
	assert.Equal(t, at2.NextSeq, at3.NextSeq, "an empty page keeps the cursor")
	var paged attemptsPage
	s.do(t, "GET", "/api/v1/sync/attempts?since=0&limit=1", "", 200, &paged)
	assert.Len(t, paged.Items, 1)
	assert.True(t, paged.HasMore)

	// States: last writer wins on updated_at; the other device pulls by server seq.
	st := func(updated int, fav bool, wrong int) string {
		f := "false"
		if fav {
			f = "true"
		}
		return `[{"question_id":"` + qid + `","fsrs":{"s":2.5},"due_at":5000,"favorite":` + f +
			`,"wrong_count":` + itoa(int64(wrong)) + `,"updated_at":` + itoa(int64(updated)) + `}]`
	}
	s.do(t, "POST", "/api/v1/sync/states", st(100, true, 1), 200, &up)
	assert.Equal(t, 1, up.Accepted)
	s.do(t, "POST", "/api/v1/sync/states", st(50, false, 9), 200, &up)
	assert.Equal(t, 1, up.Ignored, "older write loses")
	var states struct {
		Items []struct {
			QuestionID string          `json:"question_id"`
			Favorite   bool            `json:"favorite"`
			WrongCount int             `json:"wrong_count"`
			DueAt      *int64          `json:"due_at"`
			FSRS       json.RawMessage `json:"fsrs"`
		}
		NextSeq int64 `json:"next_seq"`
	}
	s.do(t, "GET", "/api/v1/sync/states?since=0", "", 200, &states)
	require.Len(t, states.Items, 1)
	assert.True(t, states.Items[0].Favorite)
	assert.Equal(t, 1, states.Items[0].WrongCount)
	assert.EqualValues(t, 5000, *states.Items[0].DueAt)
	assert.JSONEq(t, `{"s":2.5}`, string(states.Items[0].FSRS))
	var none struct{ Items []any }
	s.do(t, "GET", "/api/v1/sync/states?since="+itoa(states.NextSeq), "", 200, &none)
	assert.Empty(t, none.Items)

	// Two flags take the question offline and tell the clients to drop it.
	var f struct {
		FlagCount int64 `json:"flag_count"`
		Status    string
	}
	s.do(t, "POST", "/api/v1/questions/"+qid+"/flag", "", 200, &f)
	assert.EqualValues(t, 1, f.FlagCount)
	assert.Equal(t, "published", f.Status)
	s.do(t, "POST", "/api/v1/questions/"+qid+"/flag", "", 200, &f)
	assert.Equal(t, "needs_review", f.Status)
	var q3 syncPage
	s.do(t, "GET", "/api/v1/sync/questions?since="+itoa(q1.NextSeq), "", 200, &q3)
	assert.Empty(t, q3.Items)
	assert.Equal(t, []string{qid}, q3.Deleted)
	s.do(t, "POST", "/api/v1/questions/missing/flag", "", 404, nil)
}

// A quiz left on one device is continued on another: sessions are merged
// last-writer-wins, a finished quiz travels as a tombstone, and devices pull by
// server sequence.
func TestSyncSessions(t *testing.T) {
	s := newServer(t)

	type session struct {
		Scope     string          `json:"scope"`
		Data      json.RawMessage `json:"data"`
		UpdatedAt int64           `json:"updated_at"`
		DeviceID  string          `json:"device_id"`
		SyncSeq   int64           `json:"sync_seq"`
	}
	type page struct {
		Items   []session
		NextSeq int64 `json:"next_seq"`
		HasMore bool  `json:"has_more"`
	}
	put := func(scope, data string, updated int, device string) (res struct{ Accepted, Ignored int }) {
		if data == "" {
			data = "null"
		}
		body := `[{"scope":"` + scope + `","data":` + data + `,"updated_at":` + itoa(int64(updated)) + `,"device_id":"` + device + `"}]`
		s.do(t, "POST", "/api/v1/sync/sessions", body, 200, &res)
		return res
	}

	var empty page
	s.do(t, "GET", "/api/v1/sync/sessions?since=0", "", 200, &empty)
	assert.Empty(t, empty.Items)

	// Device A saves its position; device B pulls it.
	assert.Equal(t, 1, put("bank1", `{"index":3,"ids":["a","b","c","d"],"seed":7}`, 100, "A").Accepted)
	var p1 page
	s.do(t, "GET", "/api/v1/sync/sessions?since=0", "", 200, &p1)
	require.Len(t, p1.Items, 1)
	assert.Equal(t, "bank1", p1.Items[0].Scope)
	assert.Equal(t, "A", p1.Items[0].DeviceID)
	assert.JSONEq(t, `{"index":3,"ids":["a","b","c","d"],"seed":7}`, string(p1.Items[0].Data))
	assert.Equal(t, p1.Items[0].SyncSeq, p1.NextSeq)

	// An older write from a slow device loses; a newer one wins.
	assert.Equal(t, 1, put("bank1", `{"index":1}`, 50, "B").Ignored)
	assert.Equal(t, 1, put("bank1", `{"index":9}`, 200, "B").Accepted)
	var p2 page
	s.do(t, "GET", "/api/v1/sync/sessions?since="+itoa(p1.NextSeq), "", 200, &p2)
	require.Len(t, p2.Items, 1, "the change is visible after the cursor")
	assert.JSONEq(t, `{"index":9}`, string(p2.Items[0].Data))

	// Another bank does not interfere; finishing a quiz leaves a tombstone.
	put("bank2", `{"index":0}`, 10, "A")
	assert.Equal(t, 1, put("bank1", "", 300, "B").Accepted)
	var p3 page
	s.do(t, "GET", "/api/v1/sync/sessions?since="+itoa(p2.NextSeq), "", 200, &p3)
	require.Len(t, p3.Items, 2)
	byScope := map[string]session{}
	for _, it := range p3.Items {
		byScope[it.Scope] = it
	}
	assert.JSONEq(t, `null`, string(byScope["bank1"].Data), "finished quiz is a null-data tombstone")
	assert.JSONEq(t, `{"index":0}`, string(byScope["bank2"].Data))

	// Nothing new: the cursor stays put.
	var p4 page
	s.do(t, "GET", "/api/v1/sync/sessions?since="+itoa(p3.NextSeq), "", 200, &p4)
	assert.Empty(t, p4.Items)
	assert.Equal(t, p3.NextSeq, p4.NextSeq)

	// Bad input is rejected as a whole.
	for name, body := range map[string]string{
		"no scope":         `[{"scope":"","data":{},"updated_at":1}]`,
		"no timestamp":     `[{"scope":"b","data":{},"updated_at":0}]`,
		"long scope":       `[{"scope":"` + strings.Repeat("x", 65) + `","data":{},"updated_at":1}]`,
		"oversized data":   `[{"scope":"b","data":"` + strings.Repeat("x", 600<<10) + `","updated_at":1}]`,
		"too many":         "[" + strings.TrimSuffix(strings.Repeat(`{"scope":"b","updated_at":1},`, 51), ",") + "]",
		"not a json array": `{"scope":"b"}`,
	} {
		t.Run(name, func(t *testing.T) { s.do(t, "POST", "/api/v1/sync/sessions", body, 400, nil) })
	}
}

// A finished exam travels with the answer given to every question, so any device
// can review the paper. Uploads are idempotent on id.
func TestSyncExams(t *testing.T) {
	s := newServer(t)

	type exam struct {
		ID         string `json:"id"`
		BankID     string `json:"bank_id"`
		Title      string `json:"title"`
		FinishedAt int64  `json:"finished_at"`
		Total      int64  `json:"total"`
		Correct    int64  `json:"correct"`
		Answered   int64  `json:"answered"`
		Percent    int64  `json:"percent"`
		Passed     bool   `json:"passed"`
		LimitSec   *int64 `json:"limit_sec"`
		UsedMs     int64  `json:"used_ms"`
		DeviceID   string `json:"device_id"`
		Items      []struct {
			Q string `json:"q"`
			S []int  `json:"s"`
			C bool   `json:"c"`
		} `json:"items"`
		SyncSeq int64 `json:"sync_seq"`
	}
	type page struct {
		Items   []exam
		NextSeq int64 `json:"next_seq"`
		HasMore bool  `json:"has_more"`
	}
	body := func(id string, finished int, limit string) string {
		return `[{"id":"` + id + `","bank_id":"b1","title":"Go","finished_at":` + itoa(int64(finished)) +
			`,"total":2,"correct":1,"answered":1,"percent":50,"passed":false,"limit_sec":` + limit +
			`,"used_ms":61000,"device_id":"A","items":[{"q":"q1","s":[2],"c":true},{"q":"q2","s":[],"c":false}]}]`
	}
	var res struct{ Accepted, Ignored int }
	s.do(t, "POST", "/api/v1/sync/exams", body("E1", 100, "600"), 200, &res)
	assert.Equal(t, 1, res.Accepted)
	s.do(t, "POST", "/api/v1/sync/exams", body("E1", 100, "600"), 200, &res)
	assert.Equal(t, 1, res.Ignored, "re-upload is a no-op")

	var p1 page
	s.do(t, "GET", "/api/v1/sync/exams?since=0", "", 200, &p1)
	require.Len(t, p1.Items, 1)
	e := p1.Items[0]
	assert.Equal(t, "E1", e.ID)
	assert.Equal(t, "b1", e.BankID)
	assert.EqualValues(t, 50, e.Percent)
	assert.EqualValues(t, 600, *e.LimitSec)
	assert.EqualValues(t, 61000, e.UsedMs)
	require.Len(t, e.Items, 2)
	assert.Equal(t, []int{2}, e.Items[0].S)
	assert.True(t, e.Items[0].C)
	assert.NotNil(t, e.Items[1].S, "a blank answer is an empty list, not null")
	assert.Empty(t, e.Items[1].S)
	assert.Equal(t, e.SyncSeq, p1.NextSeq)

	// An untimed exam has a null limit; the next device only gets what is new.
	s.do(t, "POST", "/api/v1/sync/exams", body("E2", 200, "null"), 200, &res)
	var p2 page
	s.do(t, "GET", "/api/v1/sync/exams?since="+itoa(p1.NextSeq), "", 200, &p2)
	require.Len(t, p2.Items, 1)
	assert.Equal(t, "E2", p2.Items[0].ID)
	assert.Nil(t, p2.Items[0].LimitSec)
	var p3 page
	s.do(t, "GET", "/api/v1/sync/exams?since="+itoa(p2.NextSeq), "", 200, &p3)
	assert.Empty(t, p3.Items)
	assert.Equal(t, p2.NextSeq, p3.NextSeq)

	for name, b := range map[string]string{
		"no id":         `[{"id":"","bank_id":"b","title":"t","finished_at":1,"total":1,"items":[]}]`,
		"no total":      `[{"id":"x","bank_id":"b","title":"t","finished_at":1,"total":0,"items":[]}]`,
		"correct>total": `[{"id":"x","bank_id":"b","title":"t","finished_at":1,"total":1,"correct":2,"items":[]}]`,
		"bad percent":   `[{"id":"x","bank_id":"b","title":"t","finished_at":1,"total":1,"percent":101,"items":[]}]`,
		"item no q":     `[{"id":"x","bank_id":"b","title":"t","finished_at":1,"total":1,"items":[{"q":"","s":[]}]}]`,
		"too many":      "[" + strings.TrimSuffix(strings.Repeat(`{"id":"x"},`, 11), ",") + "]",
	} {
		t.Run(name, func(t *testing.T) { s.do(t, "POST", "/api/v1/sync/exams", b, 400, nil) })
	}
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }
