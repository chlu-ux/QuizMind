package service_test

import (
	"context"
	"log/slog"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/chlu-ux/quizmind/server/internal/config"
	"github.com/chlu-ux/quizmind/server/internal/db"
	"github.com/chlu-ux/quizmind/server/internal/events"
	"github.com/chlu-ux/quizmind/server/internal/jobs"
	"github.com/chlu-ux/quizmind/server/internal/llm"
	"github.com/chlu-ux/quizmind/server/internal/llm/fake"
	"github.com/chlu-ux/quizmind/server/internal/service"
)

type env struct {
	svc   *service.Service
	llm   *fake.Client
	calls *atomic.Int64
	bank  string
}

// firstSentence returns the first sentence of the excerpt, ending at "。".
func excerptOf(user string) string {
	a := strings.Index(user, "<excerpt>\n") + len("<excerpt>\n")
	b := strings.Index(user, "\n</excerpt>")
	return user[a:b]
}

func firstSentence(text string) string {
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if i := strings.Index(line, "。"); i >= 0 {
			return line[:i+len("。")]
		}
		return line
	}
	return ""
}

// scriptedLLM returns one valid single, one valid judge and one fabricated
// question for whatever excerpt it is shown.
func scriptedLLM(calls *atomic.Int64) fake.Handler {
	return func(req llm.JSONRequest) (any, error) {
		calls.Add(1)
		ex := excerptOf(req.User)
		quote := firstSentence(ex)
		short := []rune(quote)
		if len(short) > 12 {
			short = short[:12]
		}
		return map[string]any{"questions": []map[string]any{
			{
				"type": "single", "stem": "下列关于“" + string(short) + "”的描述，哪项正确？",
				"options":      []string{"选项甲" + string(short), "选项乙", "选项丙", "选项丁"},
				"answer_index": 0, "explanation": "见原文。", "difficulty": 2, "tags": []string{"测试"},
				"source_quote": quote,
			},
			{
				"type": "judge", "stem": quote + "这一说法是正确的。", "options": []string{},
				"answer_index": 0, "explanation": "原文如此。", "difficulty": 1, "tags": []string{"测试"},
				"source_quote": quote,
			},
			{
				"type": "single", "stem": "一个完全编造引文的问题是什么？",
				"options":      []string{"甲甲", "乙乙", "丙丙", "丁丁"},
				"answer_index": 1, "explanation": "", "difficulty": 3, "tags": []string{},
				"source_quote": "这是一句完全编造的引文并不存在于原文之中",
			},
		}}, nil
	}
}

func newEnv(t *testing.T) *env {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "app.db"))
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })

	cfg := config.Default()
	cfg.Pipeline.ChunkMinChars = 40
	cfg.Pipeline.ChunkMaxChars = 600
	cfg.Pipeline.QuestionsPerChunk = 3

	calls := &atomic.Int64{}
	fk := fake.New(scriptedLLM(calls))
	guard := llm.NewGuard(llm.Limits{MaxConcurrency: 2}, service.LLMRecorder{DB: d})
	reg := llm.NewRegistry()
	reg.Set(llm.RoleGenerator, guard.Wrap(llm.RoleGenerator, fk))

	hub := events.NewHub()
	q := jobs.NewQueue(d)
	log := slog.New(slog.NewTextHandler(testWriter{t}, &slog.HandlerOptions{Level: slog.LevelWarn}))
	svc := service.New(d, cfg, reg, q, hub, log)
	runner := jobs.NewRunner(d, q, 2, log, hub)
	svc.RegisterHandlers(runner)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { runner.Run(ctx); close(done) }()
	t.Cleanup(func() { cancel(); <-done })

	bank, err := svc.CreateBank(context.Background(), "测试题库", "")
	require.NoError(t, err)
	return &env{svc: svc, llm: fk, calls: calls, bank: bank.ID}
}

type testWriter struct{ t *testing.T }

func (w testWriter) Write(p []byte) (int, error) {
	w.t.Log(strings.TrimRight(string(p), "\n"))
	return len(p), nil
}

func (e *env) waitStatus(t *testing.T, docID, want string) {
	t.Helper()
	require.Eventually(t, func() bool {
		d, err := e.svc.GetDocument(context.Background(), docID)
		return err == nil && d.Status == want
	}, 10*time.Second, 25*time.Millisecond, "document should reach status %q", want)
}

func (e *env) counts(t *testing.T, docID string) map[string]int64 {
	t.Helper()
	d, err := e.svc.GetDocument(context.Background(), docID)
	require.NoError(t, err)
	return d.QuestionCounts
}

func section(title string, sentences ...string) string {
	return "## " + title + "\n\n" + strings.Join(sentences, "") + "\n\n"
}

const (
	lockA = "读写锁允许多个读者同时持有锁，但写者必须独占整个资源。这是读写锁最核心的特点之一。在读多写少的场景下，读写锁能够显著提高并发性能，因为读者之间不需要互相等待。"
	lockB = "互斥锁保证同一时刻只有一个线程可以进入临界区。持有锁的线程必须负责释放它。如果忘记释放互斥锁，其他等待该锁的线程将永远无法继续执行下去。"
	lockC = "自旋锁在获取失败时会持续循环检查锁状态，而不是让出处理器。它适合持有时间极短的场景。如果持有时间过长，自旋会白白浪费大量的处理器时间和能源。"
)

func TestPipeline_ImportGenerateReviewPublish(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	md := "# 并发\n\n" + section("读写锁", lockA) + section("互斥锁", lockB)

	res, err := e.svc.ImportDocument(ctx, e.bank, "concurrency.md", []byte(md))
	require.NoError(t, err)
	require.True(t, res.Created)
	e.waitStatus(t, res.Document.ID, "review")

	c := e.counts(t, res.Document.ID)
	assert.Equal(t, int64(4), c["needs_review"], "2 chunks x (single + judge)")
	assert.Equal(t, int64(2), c["rejected"], "2 fabricated quotes rejected automatically")
	assert.EqualValues(t, 2, e.calls.Load())

	page, err := e.svc.ListQuestions(ctx, service.QuestionFilter{Status: "rejected", DocumentID: res.Document.ID})
	require.NoError(t, err)
	require.Len(t, page.Items, 2)
	assert.Contains(t, page.Items[0].ReviewNote, "not found verbatim")

	// Title comes from the first H1.
	d, err := e.svc.GetDocument(ctx, res.Document.ID)
	require.NoError(t, err)
	assert.Equal(t, "并发", d.Title)

	// Review: approve one, edit it, reject another.
	pending, err := e.svc.ListQuestions(ctx, service.QuestionFilter{Status: "needs_review", DocumentID: res.Document.ID})
	require.NoError(t, err)
	require.Len(t, pending.Items, 4)

	pub, err := e.svc.ApproveQuestion(ctx, pending.Items[0].ID)
	require.NoError(t, err)
	assert.Equal(t, "published", pub.Status)
	require.NotNil(t, pub.SyncSeq)
	assert.EqualValues(t, 1, *pub.SyncSeq)

	again, err := e.svc.ApproveQuestion(ctx, pending.Items[0].ID)
	require.NoError(t, err)
	assert.EqualValues(t, 1, *again.SyncSeq, "approving twice does not burn a sync_seq")

	newStem := "修改后的题干：这个说法正确吗？"
	edited, err := e.svc.EditQuestion(ctx, pending.Items[0].ID, service.QuestionEdit{Stem: &newStem})
	require.NoError(t, err)
	assert.Equal(t, newStem, edited.Stem)
	require.NotNil(t, edited.SyncSeq)
	assert.EqualValues(t, 2, *edited.SyncSeq, "editing a published question republishes it")

	rej, err := e.svc.RejectQuestion(ctx, pending.Items[1].ID, "太简单")
	require.NoError(t, err)
	assert.Equal(t, "rejected", rej.Status)
	assert.Equal(t, "太简单", rej.ReviewNote)
	assert.Nil(t, rej.SyncSeq, "never-published question gets no seq")

	var single string
	for _, q := range pending.Items[2:] {
		if q.Type == "single" {
			single = q.ID
		}
	}
	require.NotEmpty(t, single, "a single-choice question is still pending")
	bad := []string{""}
	_, err = e.svc.EditQuestion(ctx, single, service.QuestionEdit{Options: &bad})
	assert.ErrorIs(t, err, service.ErrInvalid, "an invalid edit is refused and nothing changes")

	res2, err := e.svc.BulkReview(ctx, "approve", []string{pending.Items[2].ID, pending.Items[3].ID, "nope"}, "")
	require.NoError(t, err)
	assert.Equal(t, 2, res2.Done)
	assert.Contains(t, res2.Failed, "nope")
}

func TestPipeline_UnchangedReimportIsNoopAndEditsOnlyRegenerateChangedChunks(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	md1 := "# 并发\n\n" + section("读写锁", lockA) + section("互斥锁", lockB)

	r1, err := e.svc.ImportDocument(ctx, e.bank, "c.md", []byte(md1))
	require.NoError(t, err)
	e.waitStatus(t, r1.Document.ID, "review")
	require.EqualValues(t, 2, e.calls.Load())

	// Publish everything reviewable so we can watch sync_seq bumps later.
	pending, _ := e.svc.ListQuestions(ctx, service.QuestionFilter{Status: "needs_review", DocumentID: r1.Document.ID})
	ids := make([]string, 0)
	for _, q := range pending.Items {
		ids = append(ids, q.ID)
	}
	_, err = e.svc.BulkReview(ctx, "approve", ids, "")
	require.NoError(t, err)

	same, err := e.svc.ImportDocument(ctx, e.bank, "c.md", []byte(md1))
	require.NoError(t, err)
	assert.True(t, same.Unchanged)
	time.Sleep(200 * time.Millisecond)
	assert.EqualValues(t, 2, e.calls.Load(), "identical upload triggers no LLM calls")

	// Edit the 互斥锁 section, keep 读写锁 untouched, add 自旋锁.
	md2 := "# 并发\n\n" + section("读写锁", lockA) +
		section("互斥锁", "互斥锁在被占用时，其他线程会阻塞等待。解锁后等待者才会被唤醒。唤醒的顺序取决于具体的调度策略，并不保证先来先服务。") + section("自旋锁", lockC)
	r2, err := e.svc.ImportDocument(ctx, e.bank, "c.md", []byte(md2))
	require.NoError(t, err)
	assert.Equal(t, r1.Document.ID, r2.Document.ID, "same file name updates the same document")
	require.Eventually(t, func() bool { return e.calls.Load() == 4 }, 10*time.Second, 25*time.Millisecond,
		"only the edited and the new chunk are generated")
	e.waitStatus(t, r2.Document.ID, "review")
	time.Sleep(100 * time.Millisecond)
	assert.EqualValues(t, 4, e.calls.Load())

	c := e.counts(t, r2.Document.ID)
	assert.Equal(t, int64(2), c["published"], "读写锁 questions untouched")
	assert.Equal(t, int64(2), c["stale"], "old 互斥锁 questions marked stale (section edited)")
	assert.Equal(t, int64(4), c["needs_review"], "new 互斥锁 + 自旋锁 questions await review")

	d, err := e.svc.GetDocument(ctx, r2.Document.ID)
	require.NoError(t, err)
	statuses := map[string]int{}
	for _, ch := range d.Chunks {
		statuses[ch.Status]++
	}
	assert.Equal(t, 3, statuses["active"])
	assert.Equal(t, 1, statuses["stale"])

	// Now delete the 自旋锁 section entirely: its questions are retired.
	md3 := "# 并发\n\n" + section("读写锁", lockA) +
		section("互斥锁", "互斥锁在被占用时，其他线程会阻塞等待。解锁后等待者才会被唤醒。唤醒的顺序取决于具体的调度策略，并不保证先来先服务。")
	r3, err := e.svc.ImportDocument(ctx, e.bank, "c.md", []byte(md3))
	require.NoError(t, err)
	e.waitStatus(t, r3.Document.ID, "review")
	c = e.counts(t, r3.Document.ID)
	assert.Equal(t, int64(2), c["retired"], "deleted section's questions retired")
	assert.EqualValues(t, 4, e.calls.Load(), "no further generation needed")
}

func TestPipeline_DuplicateAcrossDocumentsRejected(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	md := "# 并发\n\n" + section("读写锁", lockA)

	a, err := e.svc.ImportDocument(ctx, e.bank, "a.md", []byte(md))
	require.NoError(t, err)
	e.waitStatus(t, a.Document.ID, "review")
	b, err := e.svc.ImportDocument(ctx, e.bank, "b.md", []byte(md))
	require.NoError(t, err)
	e.waitStatus(t, b.Document.ID, "review")

	cb := e.counts(t, b.Document.ID)
	assert.Equal(t, int64(0), cb["needs_review"], "all of b's valid questions duplicate a's")
	assert.Equal(t, int64(3), cb["rejected"])
	page, err := e.svc.ListQuestions(ctx, service.QuestionFilter{Status: "rejected", DocumentID: b.Document.ID})
	require.NoError(t, err)
	notes := ""
	for _, q := range page.Items {
		notes += q.ReviewNote + "\n"
	}
	assert.Contains(t, notes, "duplicate of question")
}

func TestImport_Validation(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	for name, tc := range map[string]struct {
		file string
		body []byte
	}{
		"wrong extension": {"notes.txt", []byte("# x")},
		"empty":           {"a.md", []byte("  \n ")},
		"invalid utf8":    {"a.md", []byte{0xff, 0xfe, 0xfd}},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := e.svc.ImportDocument(ctx, e.bank, tc.file, tc.body)
			assert.ErrorIs(t, err, service.ErrInvalid)
		})
	}
	_, err := e.svc.ImportDocument(ctx, "missing-bank", "a.md", []byte("# x\n\n正文内容"))
	assert.ErrorIs(t, err, service.ErrNotFound)

	// A UTF-8 BOM is stripped rather than rejected.
	body := append([]byte{0xEF, 0xBB, 0xBF}, []byte("# 标题\n\n"+lockA)...)
	_, err = e.svc.ImportDocument(ctx, e.bank, "bom.md", body)
	assert.NoError(t, err)
}

func TestListQuestions_SearchAndBankStats(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	res, err := e.svc.ImportDocument(ctx, e.bank, "locks.md", []byte("# 锁\n\n"+section("读写锁", lockA)))
	require.NoError(t, err)
	e.waitStatus(t, res.Document.ID, "review")

	all, err := e.svc.ListQuestions(ctx, service.QuestionFilter{BankID: e.bank})
	require.NoError(t, err)
	require.NotEmpty(t, all.Items)

	stem := "Needle 关键词：下面哪项正确？"
	_, err = e.svc.EditQuestion(ctx, all.Items[0].ID, service.QuestionEdit{Stem: &stem})
	require.NoError(t, err)

	hit, err := e.svc.ListQuestions(ctx, service.QuestionFilter{BankID: e.bank, Search: " needle "})
	require.NoError(t, err)
	assert.EqualValues(t, 1, hit.Total, "case-insensitive, surrounding spaces ignored")
	assert.Equal(t, all.Items[0].ID, hit.Items[0].ID)

	for _, wild := range []string{"%", "_"} {
		none, err := e.svc.ListQuestions(ctx, service.QuestionFilter{BankID: e.bank, Search: wild})
		require.NoError(t, err)
		assert.Zero(t, none.Total, "%q is matched literally, not as a wildcard", wild)
	}

	banks, err := e.svc.ListBanks(ctx)
	require.NoError(t, err)
	require.Len(t, banks, 1)
	assert.EqualValues(t, 1, banks[0].Documents)
	assert.Positive(t, banks[0].LastUpdated)
}
