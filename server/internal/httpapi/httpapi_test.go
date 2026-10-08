package httpapi_test

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"image"
	"image/png"
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
	ts    *httptest.Server
	bank  string
	reg   *llm.Registry
	guard *llm.Guard
	db    *db.DB
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

	s := &server{ts: ts, reg: reg, guard: guard, db: d}
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
			ID            string
			Answer        []int
			Options       []string
			SyncSeq       int64  `json:"sync_seq"`
			DocumentID    string `json:"document_id"`
			DocumentTitle string `json:"document_title"`
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
	assert.NotEmpty(t, q1.Items[0].DocumentID, "a question names the document (module) it came from")
	assert.NotEmpty(t, q1.Items[0].DocumentTitle)
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
			ReviewMs   *int64 `json:"review_ms"`
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

	// Review time is the one thing an uploaded attempt may still gain: it only grows, and
	// the row is published again so the other devices pick the new value up.
	assert.Nil(t, at1.Items[0].ReviewMs)
	withReview := func(ms int) string {
		return `[{"id":"A1","question_id":"` + qid + `","device_id":"d1","answer":[0],"is_correct":true,"duration_ms":1500,"review_ms":` + itoa(int64(ms)) + `,"answered_at":1000}]`
	}
	s.do(t, "POST", "/api/v1/sync/attempts", withReview(4000), 200, &up)
	assert.Equal(t, 1, up.Accepted, "a first review time is taken")
	s.do(t, "POST", "/api/v1/sync/attempts", withReview(3000), 200, &up)
	assert.Equal(t, 0, up.Accepted, "a smaller review time is ignored")
	s.do(t, "POST", "/api/v1/sync/attempts", withReview(9000), 200, &up)
	assert.Equal(t, 1, up.Accepted, "a larger one replaces it")
	var at4 attemptsPage
	s.do(t, "GET", "/api/v1/sync/attempts?since="+itoa(at3.NextSeq), "", 200, &at4)
	require.Len(t, at4.Items, 1, "the raised attempt is downloaded again")
	assert.Equal(t, "A1", at4.Items[0].ID)
	assert.EqualValues(t, 9000, *at4.Items[0].ReviewMs)
	assert.EqualValues(t, 1500, *at4.Items[0].DurationMs)
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

func TestAIConfigAccess(t *testing.T) {
	s := newServer(t)

	// An LLM endpoint stub, to check the admin "test" button end to end.
	llmSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer sk-secret-key-1234" || r.URL.Path != "/v1/chat/completions" {
			http.Error(w, `{"error":"bad key"}`, 401)
			return
		}
		_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"pong"}}]}`))
	}))
	defer llmSrv.Close()

	appGet := func(auth string) *http.Response {
		r, _ := http.NewRequest("GET", s.ts.URL+"/api/v1/ai/config", nil)
		if auth != "" {
			r.Header.Set("Authorization", "Bearer "+auth)
		}
		resp, err := http.DefaultClient.Do(r)
		require.NoError(t, err)
		resp.Body.Close()
		return resp
	}

	assert.Equal(t, 404, appGet("").StatusCode, "not configured: feature off")

	// Enabling needs a model for the explain role and an access token.
	s.do(t, "PUT", "/admin/ai", `{"enabled":true,"app_token":"1234"}`, 400, nil)

	var provider struct{ ID string }
	s.do(t, "POST", "/admin/llm/providers", `{"name":"测试","protocol":"openai","base_url":"`+llmSrv.URL+`/v1/","api_key":"sk-secret-key-1234"}`, 201, &provider)
	var model struct{ ID string }
	s.do(t, "POST", "/admin/llm/models", `{"provider_id":"`+provider.ID+`","model":"m","max_tokens":800,"temperature":0.5}`, 201, &model)
	s.do(t, "PUT", "/admin/llm/roles", `{"explain":"`+model.ID+`"}`, 200, nil)

	s.do(t, "PUT", "/admin/ai", `{"enabled":true}`, 400, nil)
	s.do(t, "PUT", "/admin/ai", `{"enabled":false,"app_token":"ab"}`, 400, nil)
	var view map[string]any
	s.do(t, "PUT", "/admin/ai", `{"enabled":true,"app_token":"1234"}`, 200, &view)
	assert.Equal(t, true, view["ready"])
	assert.Equal(t, "测试 / m", view["model_name"])
	assert.NotContains(t, view, "api_key", "the admin view never returns the key")

	var test struct {
		OK    bool
		Reply string
		Error string
	}
	s.do(t, "POST", "/admin/llm/models/"+model.ID+"/test", "", 200, &test)
	assert.True(t, test.OK, test.Error)
	assert.Equal(t, "pong", test.Reply)

	// The app gets the key only with the token.
	assert.Equal(t, 401, appGet("").StatusCode)
	assert.Equal(t, 401, appGet("wrong").StatusCode)
	var cfg struct {
		BaseURL     string  `json:"base_url"`
		APIKey      string  `json:"api_key"`
		Model       string  `json:"model"`
		MaxTokens   int     `json:"max_tokens"`
		Temperature float64 `json:"temperature"`
	}
	r, _ := http.NewRequest("GET", s.ts.URL+"/api/v1/ai/config", nil)
	r.Header.Set("Authorization", "Bearer 1234")
	resp, err := http.DefaultClient.Do(r)
	require.NoError(t, err)
	defer resp.Body.Close()
	require.Equal(t, 200, resp.StatusCode)
	require.NoError(t, json.NewDecoder(resp.Body).Decode(&cfg))
	assert.Equal(t, "sk-secret-key-1234", cfg.APIKey)
	assert.Equal(t, llmSrv.URL+"/v1", cfg.BaseURL, "trailing slash is trimmed")
	assert.Equal(t, "m", cfg.Model)
	assert.Equal(t, 800, cfg.MaxTokens)
	assert.Equal(t, 0.5, cfg.Temperature)

	// Editing the model reaches the apps on their next sync.
	s.do(t, "PUT", "/admin/llm/models/"+model.ID, `{"provider_id":"`+provider.ID+`","model":"m2","max_tokens":800,"temperature":0.5}`, 200, nil)
	r, _ = http.NewRequest("GET", s.ts.URL+"/api/v1/ai/config", nil)
	r.Header.Set("Authorization", "Bearer 1234")
	resp3, err := http.DefaultClient.Do(r)
	require.NoError(t, err)
	defer resp3.Body.Close()
	require.NoError(t, json.NewDecoder(resp3.Body).Decode(&cfg))
	assert.Equal(t, "m2", cfg.Model)

	// Switching it off withdraws the configuration, even for a valid token.
	s.do(t, "PUT", "/admin/ai", `{"enabled":false,"app_token":"1234"}`, 200, nil)
	assert.Equal(t, 404, appGet("1234").StatusCode)

	// The admin endpoints stay behind the admin token.
	resp2 := s.req(t, "GET", "/admin/ai", nil, "", false)
	resp2.Body.Close()
	assert.Equal(t, 401, resp2.StatusCode)
	resp4 := s.req(t, "GET", "/admin/llm", nil, "", false)
	resp4.Body.Close()
	assert.Equal(t, 401, resp4.StatusCode)
}

func TestLLMConfigAdmin(t *testing.T) {
	s := newServer(t)
	type provider struct {
		ID         string `json:"id"`
		Name       string `json:"name"`
		Protocol   string `json:"protocol"`
		BaseURL    string `json:"base_url"`
		APIKeySet  bool   `json:"api_key_set"`
		APIKeyHint string `json:"api_key_hint"`
	}
	type cfgView struct {
		Providers []provider
		Models    []struct {
			ID, ProviderID, Name, Model string
			MaxTokens                   int `json:"max_tokens"`
		}
		Roles  map[string]string
		Limits struct {
			MaxConcurrency   int   `json:"max_concurrency"`
			DailyTokenBudget int64 `json:"daily_token_budget"`
		}
	}

	var v cfgView
	s.do(t, "GET", "/admin/llm", "", 200, &v)
	assert.Empty(t, v.Providers)
	assert.Empty(t, v.Roles)
	assert.Equal(t, 2, v.Limits.MaxConcurrency, "defaults")

	// Validation of providers.
	for name, body := range map[string]string{
		"no name":            `{"name":"","protocol":"openai","base_url":"https://x/v1","api_key":"k"}`,
		"bad protocol":       `{"name":"a","protocol":"gemini","base_url":"https://x","api_key":"k"}`,
		"openai needs url":   `{"name":"a","protocol":"openai","api_key":"k"}`,
		"not http":           `{"name":"a","protocol":"anthropic","base_url":"ftp://x","api_key":"k"}`,
		"key needed to make": `{"name":"a","protocol":"anthropic"}`,
	} {
		t.Run(name, func(t *testing.T) { s.do(t, "POST", "/admin/llm/providers", body, 400, nil) })
	}

	var anth, oai provider
	s.do(t, "POST", "/admin/llm/providers", `{"name":"Claude","protocol":"anthropic","api_key":"sk-ant-abcdefgh1234"}`, 201, &anth)
	s.do(t, "POST", "/admin/llm/providers", `{"name":"DeepSeek","protocol":"openai","base_url":"http://127.0.0.1:1/v1","api_key":"sk-deepseek-1"}`, 201, &oai)
	assert.True(t, anth.APIKeySet)
	assert.Equal(t, "sk-…1234", anth.APIKeyHint)

	// The key is never returned, and an empty key on edit keeps it.
	raw := s.req(t, "GET", "/admin/llm", nil, "", true)
	body, _ := io.ReadAll(raw.Body)
	raw.Body.Close()
	assert.NotContains(t, string(body), "sk-ant-abcdefgh1234")
	s.do(t, "PUT", "/admin/llm/providers/"+anth.ID, `{"name":"Claude 官方","protocol":"anthropic","api_key":""}`, 200, &anth)
	assert.Equal(t, "Claude 官方", anth.Name)
	assert.True(t, anth.APIKeySet)

	// Models.
	var claude, deepseek struct{ ID string }
	s.do(t, "POST", "/admin/llm/models", `{"provider_id":"nope","model":"x"}`, 400, nil)
	s.do(t, "POST", "/admin/llm/models", `{"provider_id":"`+anth.ID+`","model":""}`, 400, nil)
	s.do(t, "POST", "/admin/llm/models", `{"provider_id":"`+anth.ID+`","model":"claude-sonnet-5-5","effort":"turbo"}`, 400, nil)
	s.do(t, "POST", "/admin/llm/models", `{"provider_id":"`+anth.ID+`","model":"claude-sonnet-5-5","effort":"medium"}`, 201, &claude)
	s.do(t, "POST", "/admin/llm/models", `{"provider_id":"`+oai.ID+`","name":"DS","model":"deepseek-chat","temperature":0.3}`, 201, &deepseek)

	// Roles: the agent needs the Anthropic protocol, the explanation the OpenAI one.
	s.do(t, "PUT", "/admin/llm/roles", `{"agent":"`+deepseek.ID+`"}`, 400, nil)
	s.do(t, "PUT", "/admin/llm/roles", `{"explain":"`+claude.ID+`"}`, 400, nil)
	s.do(t, "PUT", "/admin/llm/roles", `{"generator":"nope"}`, 400, nil)
	s.do(t, "PUT", "/admin/llm/roles", `{"singer":"`+claude.ID+`"}`, 400, nil)
	s.do(t, "PUT", "/admin/llm/roles", `{"generator":"`+deepseek.ID+`","agent":"`+claude.ID+`","explain":"`+deepseek.ID+`","validator":""}`, 200, &v)
	assert.Equal(t, map[string]string{"generator": deepseek.ID, "agent": claude.ID, "explain": deepseek.ID}, v.Roles)

	// A model in use cannot be deleted, nor a provider that still has models; and a protocol
	// change that breaks a role is refused.
	s.do(t, "DELETE", "/admin/llm/models/"+claude.ID, "", 400, nil)
	s.do(t, "DELETE", "/admin/llm/providers/"+anth.ID, "", 400, nil)
	s.do(t, "PUT", "/admin/llm/providers/"+anth.ID, `{"name":"x","protocol":"openai","base_url":"https://x/v1"}`, 400, nil)
	s.do(t, "PUT", "/admin/llm/roles", `{"generator":"`+deepseek.ID+`","explain":"`+deepseek.ID+`"}`, 200, nil)
	s.do(t, "DELETE", "/admin/llm/models/"+claude.ID, "", 204, nil)
	s.do(t, "DELETE", "/admin/llm/providers/"+anth.ID, "", 204, nil)
	s.do(t, "DELETE", "/admin/llm/providers/"+anth.ID, "", 404, nil)

	// Limits.
	s.do(t, "PUT", "/admin/llm/limits", `{"max_concurrency":0,"rps":1}`, 400, nil)
	s.do(t, "PUT", "/admin/llm/limits", `{"max_concurrency":3,"rps":-1}`, 400, nil)
	s.do(t, "PUT", "/admin/llm/limits", `{"max_concurrency":3,"rps":1.5,"daily_token_budget":500000}`, 200, &v)
	assert.Equal(t, 3, v.Limits.MaxConcurrency)
	assert.EqualValues(t, 500000, v.Limits.DailyTokenBudget)

	// A model that cannot be reached is a test result, not an error.
	var test struct {
		OK    bool
		Error string
	}
	s.do(t, "POST", "/admin/llm/models/"+deepseek.ID+"/test", "", 200, &test)
	assert.False(t, test.OK)
	assert.NotEmpty(t, test.Error)
	assert.NotContains(t, test.Error, "sk-deepseek-1")
	s.do(t, "POST", "/admin/llm/models/nope/test", "", 404, nil)
}

// enableExplain sets up an OpenAI-protocol model for the explain role and switches the feature on.
func enableExplain(t *testing.T, s *server) {
	t.Helper()
	var provider, model struct{ ID string }
	s.do(t, "POST", "/admin/llm/providers", `{"name":"P","protocol":"openai","base_url":"http://127.0.0.1:1/v1","api_key":"k"}`, 201, &provider)
	s.do(t, "POST", "/admin/llm/models", `{"provider_id":"`+provider.ID+`","model":"m"}`, 201, &model)
	s.do(t, "PUT", "/admin/llm/roles", `{"explain":"`+model.ID+`"}`, 200, nil)
	s.do(t, "PUT", "/admin/ai", `{"enabled":true,"app_token":"1234"}`, 200, nil)
}

// appPost posts to the quiz API with an access token (empty = none).
func (s *server) appPost(t *testing.T, path, token, body string, want int, out any) {
	t.Helper()
	r, _ := http.NewRequest("POST", s.ts.URL+path, strings.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(r)
	require.NoError(t, err)
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	require.Equal(t, want, resp.StatusCode, string(raw))
	if out != nil {
		require.NoError(t, json.Unmarshal(raw, out))
	}
}

func TestAIUsageReporting(t *testing.T) {
	s := newServer(t)
	qid := s.publishOne(t)
	enableExplain(t, s)
	now := time.Now().UnixMilli()
	rec := func(id string, extra string) string {
		return fmt.Sprintf(`{"id":%q,"question_id":%q,"device_id":"phone","model":"deepseek-chat","input_tokens":900,`+
			`"output_tokens":300,"cached_tokens":100,"latency_ms":2500,"ok":true,"created_at":%d%s}`, id, qid, now, extra)
	}

	// The report records spend, so it needs the access token like the configuration does.
	s.appPost(t, "/api/v1/ai/usage", "", "["+rec("u1", "")+"]", 401, nil)
	s.appPost(t, "/api/v1/ai/usage", "wrong", "["+rec("u1", "")+"]", 401, nil)

	for name, body := range map[string]string{
		"no id":           `[{"id":"","model":"m","created_at":` + fmt.Sprint(now) + `}]`,
		"negative tokens": `[{"id":"x","model":"m","input_tokens":-1,"created_at":` + fmt.Sprint(now) + `}]`,
		"no time":         `[{"id":"x","model":"m"}]`,
		"future":          `[{"id":"x","model":"m","created_at":` + fmt.Sprint(now+3*24*3600*1000) + `}]`,
		"huge":            `[{"id":"x","model":"m","output_tokens":99999999999,"created_at":` + fmt.Sprint(now) + `}]`,
		"too many":        "[" + strings.TrimSuffix(strings.Repeat(`{"id":"x"},`, 101), ",") + "]",
	} {
		t.Run(name, func(t *testing.T) { s.appPost(t, "/api/v1/ai/usage", "1234", body, 400, nil) })
	}

	var res struct{ Accepted, Ignored int }
	body := "[" + rec("u1", "") + "," + rec("u2", `,"estimated":true`) + "," +
		strings.Replace(rec("u3", ""), `"ok":true`, `"ok":false,"error":"`+strings.Repeat("错", 800)+`"`, 1) + "]"
	s.appPost(t, "/api/v1/ai/usage", "1234", body, 200, &res)
	assert.Equal(t, 3, res.Accepted)

	// Sending the same report again changes nothing.
	s.appPost(t, "/api/v1/ai/usage", "1234", body, 200, &res)
	assert.Equal(t, 0, res.Accepted)
	assert.Equal(t, 3, res.Ignored)

	var usage []struct {
		Day, Source, Role, Model string
		Calls, Failures          int64
		EstimatedCalls           int64 `json:"estimated_calls"`
		InputTokens              int64 `json:"input_tokens"`
		CachedTokens             int64 `json:"cached_tokens"`
	}
	s.do(t, "GET", "/admin/usage", "", 200, &usage)
	var client, server *struct {
		Day, Source, Role, Model string
		Calls, Failures          int64
		EstimatedCalls           int64 `json:"estimated_calls"`
		InputTokens              int64 `json:"input_tokens"`
		CachedTokens             int64 `json:"cached_tokens"`
	}
	for i := range usage {
		switch usage[i].Source {
		case "client":
			client = &usage[i]
		case "server":
			server = &usage[i]
		}
	}
	require.NotNil(t, client)
	assert.Equal(t, "explain", client.Role)
	assert.Equal(t, "deepseek-chat", client.Model)
	assert.EqualValues(t, 3, client.Calls)
	assert.EqualValues(t, 1, client.Failures)
	assert.EqualValues(t, 1, client.EstimatedCalls)
	assert.EqualValues(t, 2700, client.InputTokens)
	assert.EqualValues(t, 300, client.CachedTokens)
	assert.Equal(t, time.Now().Format("2006-01-02"), client.Day, "days are in the server's local time")
	if server != nil {
		assert.Equal(t, "generator", server.Role)
	}

	type call struct {
		ID           string `json:"id"`
		Source       string
		Role         string
		OK           bool   `json:"ok"`
		Error        string `json:"error"`
		DeviceID     string `json:"device_id"`
		QuestionID   string `json:"question_id"`
		QuestionStem string `json:"question_stem"`
		BankTitle    string `json:"bank_title"`
		Estimated    bool
	}
	var calls struct {
		Items []call
		Total int64
	}
	s.do(t, "GET", "/admin/usage/calls?source=client", "", 200, &calls)
	assert.EqualValues(t, 3, calls.Total)
	require.Len(t, calls.Items, 3)
	assert.Equal(t, "phone", calls.Items[0].DeviceID)
	assert.Equal(t, qid, calls.Items[0].QuestionID)
	assert.NotEmpty(t, calls.Items[0].QuestionStem, "the call shows which question it explained")
	assert.Equal(t, "题库", calls.Items[0].BankTitle)

	s.do(t, "GET", "/admin/usage/calls?source=client&failed=1", "", 200, &calls)
	require.Len(t, calls.Items, 1)
	assert.Equal(t, "u3", calls.Items[0].ID)
	assert.Len(t, []rune(calls.Items[0].Error), 500, "a long error is cut")
	s.do(t, "GET", "/admin/usage/calls?role=generator", "", 200, &calls)
	for _, c := range calls.Items {
		assert.Equal(t, "server", c.Source)
	}
	s.do(t, "GET", "/admin/usage/calls?limit=1&offset=1&source=client", "", 200, &calls)
	assert.Len(t, calls.Items, 1)
	assert.EqualValues(t, 3, calls.Total)

	// Still accepted after the feature is switched off: a queued report is not lost.
	s.do(t, "PUT", "/admin/ai", `{"enabled":false,"app_token":"1234"}`, 200, nil)
	s.appPost(t, "/api/v1/ai/usage", "1234", "["+rec("u4", "")+"]", 200, &res)
	assert.Equal(t, 1, res.Accepted)
}

func TestSyncNotes(t *testing.T) {
	s := newServer(t)
	qid := s.publishOne(t)

	type note struct {
		QuestionID    string `json:"question_id"`
		Content       string `json:"content"`
		Model         string `json:"model"`
		PromptVersion string `json:"prompt_version"`
		Selected      []int  `json:"selected"`
		UpdatedAt     int64  `json:"updated_at"`
		DeviceID      string `json:"device_id"`
		SyncSeq       int64  `json:"sync_seq"`
	}
	type page struct {
		Items   []note
		NextSeq int64 `json:"next_seq"`
		HasMore bool  `json:"has_more"`
	}
	put := func(content string, updated int64, device string) (res struct{ Accepted, Ignored int }) {
		body, _ := json.Marshal([]note{{QuestionID: qid, Content: content, Model: "m", PromptVersion: "v1", Selected: []int{1}, UpdatedAt: updated, DeviceID: device}})
		s.do(t, "POST", "/api/v1/sync/notes", string(body), 200, &res)
		return res
	}

	assert.Equal(t, 1, put("第一版", 100, "a").Accepted)
	assert.Equal(t, 1, put("重新生成", 200, "b").Accepted, "a newer explanation replaces the old one")
	assert.Equal(t, 1, put("过期的", 150, "a").Ignored, "an older one is ignored")

	var p page
	s.do(t, "GET", "/api/v1/sync/notes?since=0", "", 200, &p)
	require.Len(t, p.Items, 1)
	assert.Equal(t, "重新生成", p.Items[0].Content)
	assert.Equal(t, []int{1}, p.Items[0].Selected)
	assert.Equal(t, "b", p.Items[0].DeviceID)

	var none page
	s.do(t, "GET", "/api/v1/sync/notes?since="+itoa(p.NextSeq), "", 200, &none)
	assert.Empty(t, none.Items)

	// Unknown questions are skipped; bad input is rejected.
	var res struct{ Accepted, Ignored int }
	s.do(t, "POST", "/api/v1/sync/notes", `[{"question_id":"nope","content":"x","updated_at":1}]`, 200, &res)
	assert.Equal(t, 1, res.Ignored)
	s.do(t, "POST", "/api/v1/sync/notes", `[{"question_id":"`+qid+`","content":"  ","updated_at":1}]`, 400, nil)
	s.do(t, "POST", "/api/v1/sync/notes", `[{"question_id":"`+qid+`","content":"x","updated_at":0}]`, 400, nil)
}

func TestAdminListAINotes(t *testing.T) {
	s := newServer(t)
	qid := s.publishOne(t)

	type page struct {
		Items []struct {
			QuestionID string   `json:"question_id"`
			BankTitle  string   `json:"bank_title"`
			Stem       string   `json:"stem"`
			Options    []string `json:"options"`
			Answer     []int    `json:"answer"`
			Content    string   `json:"content"`
			Selected   []int    `json:"selected"`
		}
		Total int64
	}
	var p page
	s.do(t, "GET", "/admin/ai/notes", "", 200, &p)
	assert.Empty(t, p.Items)
	assert.Zero(t, p.Total)

	var res struct{ Accepted, Ignored int }
	body := `[{"question_id":"` + qid + `","content":"## 解析\n因为……","model":"m","selected":[1],"updated_at":100,"device_id":"a"}]`
	s.do(t, "POST", "/api/v1/sync/notes", body, 200, &res)

	s.do(t, "GET", "/admin/ai/notes", "", 200, &p)
	require.Len(t, p.Items, 1)
	assert.Equal(t, int64(1), p.Total)
	assert.Equal(t, qid, p.Items[0].QuestionID)
	assert.NotEmpty(t, p.Items[0].Stem)
	assert.NotEmpty(t, p.Items[0].Options)
	assert.NotEmpty(t, p.Items[0].BankTitle)
	assert.Equal(t, []int{1}, p.Items[0].Selected)
	assert.Contains(t, p.Items[0].Content, "因为")

	s.do(t, "GET", "/admin/ai/notes?search=因为", "", 200, &p)
	assert.Len(t, p.Items, 1)
	s.do(t, "GET", "/admin/ai/notes?search=不存在的内容", "", 200, &p)
	assert.Empty(t, p.Items)
	assert.Zero(t, p.Total)
	s.do(t, "GET", "/admin/ai/notes?bank_id=nope", "", 200, &p)
	assert.Empty(t, p.Items)
}

func TestDocumentContent(t *testing.T) {
	s := newServer(t)
	resp := s.upload(t, "notes.md", doc)
	require.Equal(t, 201, resp.StatusCode)
	var res struct{ Document struct{ ID string } }
	require.NoError(t, json.NewDecoder(resp.Body).Decode(&res))
	resp.Body.Close()

	var d struct {
		ID, Content string
		SourcePath  string `json:"source_path"`
	}
	s.do(t, "GET", "/admin/documents/"+res.Document.ID+"/content", "", 200, &d)
	assert.Equal(t, res.Document.ID, d.ID)
	assert.Equal(t, "notes.md", d.SourcePath)
	assert.Equal(t, doc, d.Content, "the stored source comes back unchanged")
	s.do(t, "GET", "/admin/documents/nope/content", "", 404, nil)
}

type flagView struct {
	Status     string `json:"status"`
	ReviewNote string `json:"review_note"`
	FlagCount  int64  `json:"flag_count"`
	SyncSeq    *int64 `json:"sync_seq"`
}

type flagDetail struct {
	flagView
	Flags []struct {
		Reason     string `json:"reason"`
		CreatedAt  int64  `json:"created_at"`
		ResolvedAt *int64 `json:"resolved_at"`
	} `json:"flags"`
}

func (s *server) flag(t *testing.T, qid, body string) (f struct {
	FlagCount int64 `json:"flag_count"`
	Status    string
}) {
	t.Helper()
	s.do(t, "POST", "/api/v1/questions/"+qid+"/flag", body, 200, &f)
	return f
}

// Reports carry a reason, show up in the admin filter whatever the status, and
// are settled by the reviewer: approving a question the reports took offline
// clears them, so the next report does not take it straight down again.
func TestFlagReview(t *testing.T) {
	s := newServer(t)
	qid := s.publishOne(t)

	// Old clients send no body; unknown reasons fall back to "other".
	assert.EqualValues(t, 1, s.flag(t, qid, "").FlagCount)
	var d flagDetail
	s.do(t, "GET", "/admin/questions/"+qid, "", 200, &d)
	require.Len(t, d.Flags, 1)
	assert.Equal(t, "other", d.Flags[0].Reason)
	assert.Nil(t, d.Flags[0].ResolvedAt)

	// One report keeps the question published but makes it show up under flagged=1.
	var page struct {
		Items []struct{ ID string }
		Total int
	}
	s.do(t, "GET", "/admin/questions?flagged=1", "", 200, &page)
	require.Equal(t, 1, page.Total)
	assert.Equal(t, qid, page.Items[0].ID)
	var banks []struct {
		QuestionCounts map[string]int64 `json:"question_counts"`
	}
	s.do(t, "GET", "/admin/banks", "", 200, &banks)
	assert.EqualValues(t, 1, banks[0].QuestionCounts["flagged"])

	// The second report, with a reason, takes it offline.
	assert.Equal(t, "needs_review", s.flag(t, qid, `{"reason":"wrong_answer"}`).Status)
	s.do(t, "GET", "/admin/questions/"+qid, "", 200, &d)
	require.Len(t, d.Flags, 2)
	assert.Equal(t, "wrong_answer", d.Flags[0].Reason, "newest first")
	assert.Equal(t, "flagged by app users", d.ReviewNote)
	s.do(t, "GET", "/admin/questions?flagged=1&status=needs_review", "", 200, &page)
	assert.Equal(t, 1, page.Total, "offline questions stay in the flagged list")

	// Approving settles the reports; the next one starts from zero.
	var v flagView
	s.do(t, "POST", "/admin/questions/"+qid+"/approve", "", 200, &v)
	assert.Equal(t, "published", v.Status)
	assert.EqualValues(t, 0, v.FlagCount)
	s.do(t, "GET", "/admin/questions?flagged=1", "", 200, &page)
	assert.Equal(t, 0, page.Total)
	s.do(t, "GET", "/admin/questions/"+qid, "", 200, &d)
	require.Len(t, d.Flags, 2)
	for _, f := range d.Flags {
		assert.NotNil(t, f.ResolvedAt)
	}
	f := s.flag(t, qid, `{"reason":"typo"}`)
	assert.EqualValues(t, 1, f.FlagCount)
	assert.Equal(t, "published", f.Status, "no instant second take-down")

	// An unknown reason is stored as "other".
	s.flag(t, qid, `{"reason":"nonsense"}`)
	s.do(t, "GET", "/admin/questions/"+qid, "", 200, &d)
	assert.Equal(t, "other", d.Flags[0].Reason)
}

func TestDismissFlags(t *testing.T) {
	s := newServer(t)
	qid := s.publishOne(t)
	seqOf := func() int64 {
		var v flagView
		s.do(t, "GET", "/admin/questions/"+qid, "", 200, &v)
		require.NotNil(t, v.SyncSeq)
		return *v.SyncSeq
	}

	// Published with one report: cleared, and re-announced so a device that
	// hid it after its own report gets it back.
	s.flag(t, qid, `{"reason":"ambiguous"}`)
	before := seqOf()
	var v flagView
	s.do(t, "POST", "/admin/questions/"+qid+"/dismiss-flags", "", 200, &v)
	assert.Equal(t, "published", v.Status)
	assert.EqualValues(t, 0, v.FlagCount)
	assert.Greater(t, seqOf(), before)

	// Taken offline by reports: dismissing publishes it again and drops the note.
	s.flag(t, qid, "")
	s.flag(t, qid, "")
	s.do(t, "GET", "/admin/questions/"+qid, "", 200, &v)
	require.Equal(t, "needs_review", v.Status)
	before = seqOf()
	s.do(t, "POST", "/admin/questions/"+qid+"/dismiss-flags", "", 200, &v)
	assert.Equal(t, "published", v.Status)
	assert.Empty(t, v.ReviewNote)
	assert.EqualValues(t, 0, v.FlagCount)
	assert.Greater(t, seqOf(), before)
	var q struct {
		Items   []struct{ ID string }
		Deleted []string
	}
	s.do(t, "GET", "/api/v1/sync/questions?since="+itoa(before), "", 200, &q)
	require.Len(t, q.Items, 1, "the clients are told to take it back")

	// Rejecting a flagged question settles its reports too, and dismissing on a
	// question that is offline for another reason does not publish it.
	s.flag(t, qid, "")
	s.do(t, "POST", "/admin/questions/"+qid+"/reject", "", 200, &v)
	assert.Equal(t, "rejected", v.Status)
	assert.EqualValues(t, 0, v.FlagCount)
	s.do(t, "POST", "/admin/questions/"+qid+"/dismiss-flags", "", 200, &v)
	assert.Equal(t, "rejected", v.Status)
	s.do(t, "POST", "/admin/questions/missing/dismiss-flags", "", 404, nil)
}

func (s *server) uploadMedia(t *testing.T, filename string, content []byte, auth bool) *http.Response {
	t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	fw, err := mw.CreateFormFile("file", filename)
	require.NoError(t, err)
	_, _ = fw.Write(content)
	require.NoError(t, mw.Close())
	return s.req(t, "POST", "/admin/media", &buf, mw.FormDataContentType(), auth)
}

func TestMedia(t *testing.T) {
	s := newServer(t)

	var pic bytes.Buffer
	require.NoError(t, png.Encode(&pic, image.NewRGBA(image.Rect(0, 0, 40, 30))))

	resp := s.uploadMedia(t, "uml.png", pic.Bytes(), false)
	resp.Body.Close()
	assert.Equal(t, 401, resp.StatusCode, "uploading needs the admin token")

	resp = s.uploadMedia(t, "uml.png", pic.Bytes(), true)
	require.Equal(t, 201, resp.StatusCode)
	var m struct {
		ID, Ref, Mime string
		Width, Height int
	}
	require.NoError(t, json.NewDecoder(resp.Body).Decode(&m))
	resp.Body.Close()
	assert.Equal(t, "media:"+m.ID, m.Ref)
	assert.Equal(t, "image/png", m.Mime)
	assert.Equal(t, [2]int{40, 30}, [2]int{m.Width, m.Height})

	// The same bytes give the same id.
	resp = s.uploadMedia(t, "again.png", pic.Bytes(), true)
	var again struct{ ID string }
	require.NoError(t, json.NewDecoder(resp.Body).Decode(&again))
	resp.Body.Close()
	assert.Equal(t, m.ID, again.ID)

	// The type is judged by content: a script renamed to .png is refused, and so is an SVG that could run code.
	for _, bad := range []string{
		"alert(1)",
		`<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>`,
		`<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"></svg>`,
		`<svg xmlns="http://www.w3.org/2000/svg"><foreignObject/></svg>`,
		`<svg xmlns="http://www.w3.org/2000/svg"><image href="http://x.test/a.png"/></svg>`,
		`<svg xmlns="http://www.w3.org/2000/svg"><use href="http://x.test/a.svg#b"/></svg>`,
		`<svg xmlns="http://www.w3.org/2000/svg"><rect fill="url(http://x.test/a)"/></svg>`,
		`<!DOCTYPE svg [<!ENTITY a "b">]><svg xmlns="http://www.w3.org/2000/svg"></svg>`,
		`<svg><rect/></svg>`, // no namespace: browsers would not draw it
	} {
		resp = s.uploadMedia(t, "x.png", []byte(bad), true)
		resp.Body.Close()
		assert.Equal(t, 400, resp.StatusCode, bad)
	}

	// A plain SVG diagram is accepted, whatever the file is called, and served as a dead drawing.
	svg := `<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" width="120px" viewBox="0 0 120 80"><rect x="1" y="1" width="50" height="30" fill="url(#g)"/><text x="5" y="20">类</text></svg>`
	resp = s.uploadMedia(t, "class.svg", []byte(svg), true)
	require.Equal(t, 201, resp.StatusCode)
	var sv struct {
		ID, Mime      string
		Width, Height int
	}
	require.NoError(t, json.NewDecoder(resp.Body).Decode(&sv))
	resp.Body.Close()
	assert.Equal(t, "image/svg+xml", sv.Mime)
	assert.Equal(t, [2]int{120, 80}, [2]int{sv.Width, sv.Height}, "width from the attribute, height from the viewBox")
	resp = s.req(t, "GET", "/api/v1/media/"+sv.ID, nil, "", false)
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	require.Equal(t, 200, resp.StatusCode)
	assert.Equal(t, svg, string(body))
	assert.Equal(t, "image/svg+xml", resp.Header.Get("Content-Type"))
	assert.Contains(t, resp.Header.Get("Content-Security-Policy"), "sandbox")
	resp = s.uploadMedia(t, "x.png", append([]byte("\x89PNG\r\n\x1a\n"), "junk"...), true)
	resp.Body.Close()
	assert.Equal(t, 400, resp.StatusCode, "a truncated PNG is not an image")

	// Phones fetch it without a token.
	resp = s.req(t, "GET", "/api/v1/media/"+m.ID, nil, "", false)
	body, _ = io.ReadAll(resp.Body)
	resp.Body.Close()
	require.Equal(t, 200, resp.StatusCode)
	assert.Equal(t, pic.Bytes(), body)
	assert.Equal(t, "image/png", resp.Header.Get("Content-Type"))
	assert.Contains(t, resp.Header.Get("Cache-Control"), "immutable")
	assert.Equal(t, "nosniff", resp.Header.Get("X-Content-Type-Options"))

	resp = s.req(t, "GET", "/api/v1/media/000000000000000000000000", nil, "", false)
	resp.Body.Close()
	assert.Equal(t, 404, resp.StatusCode)

	// A question may reference an uploaded picture, but not one that does not exist.
	up := s.upload(t, "notes.md", doc)
	require.Equal(t, 201, up.StatusCode)
	var res struct{ Document struct{ ID string } }
	require.NoError(t, json.NewDecoder(up.Body).Decode(&res))
	up.Body.Close()
	var page struct{ Items []struct{ ID string } }
	require.Eventually(t, func() bool {
		s.do(t, "GET", "/admin/questions?status=needs_review&document_id="+res.Document.ID, "", 200, &page)
		return len(page.Items) == 1
	}, 10*time.Second, 25*time.Millisecond)
	id := page.Items[0].ID

	var edited struct{ Stem string }
	s.do(t, "PATCH", "/admin/questions/"+id, `{"stem":"如图所示的读写锁类图中，哪个说法正确？\n\n![类图](`+m.Ref+`)"}`, 200, &edited)
	assert.Contains(t, edited.Stem, m.Ref)
	s.do(t, "PATCH", "/admin/questions/"+id, `{"stem":"如图所示的读写锁类图中，哪个说法正确？![类图](media:0123456789abcdef01234567)"}`, 400, nil)
	s.do(t, "PATCH", "/admin/questions/"+id, `{"options":["![](`+m.Ref+`)","b","c","d"]}`, 200, nil)
}
