// Command devseed fills a QuizMind database with a sample document and
// hand-written questions so the admin UI has something to review without an
// LLM API key.
//
// The questions go through the real pipeline (chunking, rule validation,
// de-duplication), so source quotes are checked against the sample text exactly
// as they would be for model output. Two fixtures are deliberately bad (a
// duplicate and a fabricated quote) to exercise the "rejected" states.
package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/chlu-ux/quizmind/server/internal/config"
	"github.com/chlu-ux/quizmind/server/internal/db"
	"github.com/chlu-ux/quizmind/server/internal/events"
	"github.com/chlu-ux/quizmind/server/internal/jobs"
	"github.com/chlu-ux/quizmind/server/internal/llm"
	"github.com/chlu-ux/quizmind/server/internal/service"
	"github.com/chlu-ux/quizmind/server/internal/store"
)

//go:embed seed/go-concurrency.md
var sampleDoc []byte

//go:embed seed/questions.json
var fixtureJSON []byte

const bankTitle = "Go 并发（示例）"

// fixtureClient answers generation requests from the fixture, keyed by the
// "Section path:" line the real prompt carries.
type fixtureClient struct{ byPath map[string][]json.RawMessage }

func (fixtureClient) Name() string  { return "seed" }
func (fixtureClient) Model() string { return "seed-fixture" }

func (f fixtureClient) GenerateJSON(_ context.Context, req llm.JSONRequest, out any) (llm.Usage, error) {
	path := ""
	for _, line := range strings.Split(req.User, "\n") {
		if p, ok := strings.CutPrefix(line, "Section path: "); ok {
			path = strings.TrimSpace(p)
			break
		}
	}
	qs := f.byPath[path]
	raw, err := json.Marshal(map[string]any{"questions": qs})
	if err != nil {
		return llm.Usage{}, err
	}
	return llm.Usage{}, json.Unmarshal(raw, out)
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "devseed:", err)
		os.Exit(1)
	}
}

func run() error {
	configPath := flag.String("config", "", "config YAML (same one the server uses, so both share data_dir)")
	approve := flag.Int("approve", 6, "publish this many of the valid questions so the bank has published data (-1 = all of them)")
	appendDoc := flag.Bool("append", false, "add the document to the existing bank with this title instead of stopping")
	docPath := flag.String("doc", "", "Markdown file to import instead of the built-in sample")
	questionsPath := flag.String("questions", "", "hand-written questions JSON keyed by section path (required with -doc)")
	title := flag.String("bank", "", "bank title (required with -doc)")
	desc := flag.String("desc", "", "bank description (with -doc)")
	images := flag.String("images", "", "folder holding the pictures that the document and the questions reference by relative path, e.g. ![](uml/class.png) (default: the folder of -doc)")
	flag.Parse()

	// Built-in sample unless the caller brings their own material. Hand-written
	// questions still go through the real pipeline, so every source_quote is
	// checked against the document text exactly as model output would be.
	doc, fixture, bankName, bankDesc := sampleDoc, fixtureJSON, bankTitle,
		"由 devseed 生成的示例题库：手写题目，经过真实的校验与去重流水线。"
	docName := "go-concurrency.md"
	if *docPath != "" {
		if *questionsPath == "" || *title == "" {
			return fmt.Errorf("-doc needs -questions and -bank")
		}
		var err error
		if doc, err = os.ReadFile(*docPath); err != nil {
			return err
		}
		if fixture, err = os.ReadFile(*questionsPath); err != nil {
			return err
		}
		bankName, bankDesc, docName = *title, *desc, filepath.Base(*docPath)
		if *images == "" {
			*images = filepath.Dir(*docPath)
		}
	}

	cfg, err := config.Load(*configPath)
	if err != nil {
		return err
	}
	// Small chunks so each section of the sample becomes its own chunk.
	cfg.Pipeline.ChunkMinChars = 100
	cfg.Pipeline.QuestionsPerChunk = 10

	d, err := db.Open(cfg.DBPath())
	if err != nil {
		return err
	}
	defer d.Close()

	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	hub := events.NewHub()
	q := jobs.NewQueue(d)
	reg := llm.NewRegistry()
	guard := llm.NewGuard(llm.Limits{MaxConcurrency: 4}, service.LLMRecorder{DB: d})
	svc := service.New(d, cfg, reg, q, hub, log)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Pictures written as relative paths are uploaded and replaced by media: references, in the
	// document (so the admin can show it) and in the questions.
	if *images != "" {
		text, err := svc.ImportLocalImages(ctx, string(doc), *images)
		if err != nil {
			return fmt.Errorf("document: %w", err)
		}
		doc = []byte(text)
		if text, err = svc.ImportLocalImages(ctx, string(fixture), *images); err != nil {
			return fmt.Errorf("questions: %w", err)
		}
		fixture = []byte(text)
	}
	var byPath map[string][]json.RawMessage
	if err := json.Unmarshal(fixture, &byPath); err != nil {
		return fmt.Errorf("fixture: %w", err)
	}
	reg.Set(llm.RoleGenerator, guard.Wrap(llm.RoleGenerator, fixtureClient{byPath: byPath}))

	banks, err := svc.ListBanks(ctx)
	if err != nil {
		return err
	}
	var bank store.Bank
	found := false
	for _, b := range banks {
		if b.Title == bankName {
			if !*appendDoc {
				fmt.Printf("bank %q already exists (id %s); nothing to do (use -append to add a document)\n", bankName, b.ID)
				return nil
			}
			bank, found = b.Bank, true
			break
		}
	}

	runner := jobs.NewRunner(d, q, 2, log, hub)
	svc.RegisterHandlers(runner)
	done := make(chan struct{})
	go func() { runner.Run(ctx); close(done) }()

	if !found {
		if bank, err = svc.CreateBank(ctx, bankName, bankDesc); err != nil {
			return err
		}
	}
	res, err := svc.ImportDocument(ctx, bank.ID, docName, doc)
	if err != nil {
		return err
	}

	deadline := time.Now().Add(30 * time.Second)
	for {
		doc, err := svc.GetDocument(ctx, res.Document.ID)
		if err != nil {
			return err
		}
		if doc.Status == "review" || doc.Status == "failed" {
			if doc.Status == "failed" {
				return fmt.Errorf("document processing failed")
			}
			break
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("timed out waiting for the pipeline")
		}
		time.Sleep(50 * time.Millisecond)
	}
	cancel()
	<-done

	ctx = context.Background()
	docID := res.Document.ID
	if *approve != 0 {
		// Only this document's questions: in append mode the bank may hold
		// others that are still waiting for the reviewer.
		page, err := svc.ListQuestions(ctx, service.QuestionFilter{Status: "needs_review", BankID: bank.ID, DocumentID: docID, Limit: 200})
		if err != nil {
			return err
		}
		n := 0
		// ListQuestions is newest-first; approve from the oldest.
		for i := len(page.Items) - 1; i >= 0 && (*approve < 0 || n < *approve); i-- {
			if _, err := svc.ApproveQuestion(ctx, page.Items[i].ID); err != nil {
				return err
			}
			n++
		}
	}

	// Rejections are the interesting part when iterating on a fixture: say why.
	rejected, err := svc.ListQuestions(ctx, service.QuestionFilter{Status: "rejected", BankID: bank.ID, DocumentID: docID, Limit: 200})
	if err != nil {
		return err
	}
	for _, q := range rejected.Items {
		fmt.Printf("rejected: %s\n    %s\n", truncate(q.Stem, 40), q.ReviewNote)
	}

	counts, err := svc.ListBanks(ctx)
	if err != nil {
		return err
	}
	for _, b := range counts {
		if b.ID == bank.ID {
			fmt.Printf("bank %q (id %s): %v\n", b.Title, b.ID, b.QuestionCounts)
		}
	}
	return nil
}

func truncate(s string, n int) string {
	if r := []rune(s); len(r) > n {
		return string(r[:n]) + "…"
	}
	return s
}
