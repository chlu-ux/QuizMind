package service

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"path/filepath"
	"strings"
	"unicode/utf8"

	"github.com/chlu-ux/quizmind/server/internal/events"
	"github.com/chlu-ux/quizmind/server/internal/store"
)

// ---- banks ----

type BankView struct {
	store.Bank
	Documents      int64            `json:"documents"`
	LastUpdated    int64            `json:"last_updated"`
	QuestionCounts map[string]int64 `json:"question_counts"`
}

func (s *Service) CreateBank(ctx context.Context, title, description string) (store.Bank, error) {
	title = strings.TrimSpace(title)
	if title == "" || len([]rune(title)) > 100 {
		return store.Bank{}, invalid("title is required (max 100 characters)")
	}
	return store.New(s.DB.Write).CreateBank(ctx, store.CreateBankParams{
		ID: newID(), Title: title, Description: strings.TrimSpace(description), CreatedAt: nowMs(),
	})
}

func (s *Service) ListBanks(ctx context.Context) ([]BankView, error) {
	qs := s.reader()
	banks, err := qs.ListBanks(ctx)
	if err != nil {
		return nil, err
	}
	stats, err := qs.BankDocumentStats(ctx)
	if err != nil {
		return nil, err
	}
	docs := map[string]store.BankDocumentStatsRow{}
	for _, st := range stats {
		docs[st.BankID] = st
	}
	out := make([]BankView, 0, len(banks))
	for _, b := range banks {
		counts, err := s.questionCounts(ctx, b.ID)
		if err != nil {
			return nil, err
		}
		st := docs[b.ID]
		last, _ := st.LastUpdated.(int64)
		if last == 0 {
			last = b.CreatedAt
		}
		out = append(out, BankView{Bank: b, Documents: st.Documents, LastUpdated: last, QuestionCounts: counts})
	}
	return out, nil
}

func (s *Service) questionCounts(ctx context.Context, bankID string) (map[string]int64, error) {
	var arg any
	if bankID != "" {
		arg = bankID
	}
	rows, err := s.reader().QuestionStatusCounts(ctx, arg)
	if err != nil {
		return nil, err
	}
	m := map[string]int64{}
	for _, r := range rows {
		m[r.Status] = r.N
	}
	// "flagged" is not a status: it counts the questions with unresolved reports,
	// which can sit in any status, so it overlaps the others.
	flagged, err := s.reader().CountFlaggedQuestions(ctx, arg)
	if err != nil {
		return nil, err
	}
	if flagged > 0 {
		m["flagged"] = flagged
	}
	return m, nil
}

// ---- documents ----

type ImportResult struct {
	Document  DocumentView `json:"document"`
	Created   bool         `json:"created"`
	Unchanged bool         `json:"unchanged"`
}

// ImportDocument stores an uploaded Markdown file and queues chunking. Uploading
// the same file name into the same bank again updates the document in place;
// identical content is a no-op.
func (s *Service) ImportDocument(ctx context.Context, bankID, filename string, content []byte) (ImportResult, error) {
	name := filepath.Base(strings.ReplaceAll(filename, "\\", "/"))
	ext := strings.ToLower(filepath.Ext(name))
	if name == "" || name == "." || (ext != ".md" && ext != ".markdown") {
		return ImportResult{}, invalid("only .md or .markdown files are accepted")
	}
	if len(content) > s.Cfg.Pipeline.MaxUploadBytes {
		return ImportResult{}, invalid("file larger than %d bytes", s.Cfg.Pipeline.MaxUploadBytes)
	}
	content = bytes.TrimPrefix(content, []byte{0xEF, 0xBB, 0xBF}) // UTF-8 BOM
	if !utf8.Valid(content) {
		return ImportResult{}, invalid("file is not valid UTF-8")
	}
	text := string(content)
	if strings.TrimSpace(text) == "" {
		return ImportResult{}, invalid("file is empty")
	}
	sum := sha256.Sum256(content)
	hash := hex.EncodeToString(sum[:])
	title := strings.TrimSuffix(name, filepath.Ext(name))

	if _, err := s.reader().GetBank(ctx, bankID); err != nil {
		return ImportResult{}, notFound(err, "bank")
	}

	var res ImportResult
	err := s.DB.WithTx(ctx, func(tx *sql.Tx) error {
		qs := store.New(tx)
		now := nowMs()
		existing, err := qs.GetDocumentBySourcePath(ctx, store.GetDocumentBySourcePathParams{BankID: bankID, SourcePath: name})
		switch {
		case err == nil && existing.ContentHash == hash:
			res = ImportResult{Document: docView(existing, nil), Unchanged: true}
			return nil
		case err == nil:
			if err := qs.UpdateDocumentContent(ctx, store.UpdateDocumentContentParams{
				Title: existing.Title, Content: text, ContentHash: hash, Status: "chunking", UpdatedAt: now, ID: existing.ID,
			}); err != nil {
				return err
			}
			existing.Status, existing.UpdatedAt = "chunking", now
			res = ImportResult{Document: docView(existing, nil)}
		case errors.Is(err, sql.ErrNoRows):
			doc, err := qs.CreateDocument(ctx, store.CreateDocumentParams{
				ID: newID(), BankID: bankID, Title: title, SourcePath: name, Content: text,
				ContentHash: hash, Status: "chunking", CreatedAt: now, UpdatedAt: now,
			})
			if err != nil {
				return err
			}
			res = ImportResult{Document: docView(doc, nil), Created: true}
		default:
			return err
		}
		_, err = s.Queue.EnqueueTx(ctx, qs, JobChunkDocument, res.Document.ID, map[string]string{"document_id": res.Document.ID})
		return err
	})
	if err != nil {
		return ImportResult{}, err
	}
	if !res.Unchanged {
		s.Queue.Notify()
		s.publishDoc(res.Document.ID, res.Document.Status)
	}
	return res, nil
}

type DocumentView struct {
	ID             string           `json:"id"`
	BankID         string           `json:"bank_id"`
	Title          string           `json:"title"`
	SourcePath     string           `json:"source_path"`
	Status         string           `json:"status"`
	CreatedAt      int64            `json:"created_at"`
	UpdatedAt      int64            `json:"updated_at"`
	QuestionCounts map[string]int64 `json:"question_counts"`
}

func docView(d store.Document, counts map[string]int64) DocumentView {
	if counts == nil {
		counts = map[string]int64{}
	}
	return DocumentView{ID: d.ID, BankID: d.BankID, Title: d.Title, SourcePath: d.SourcePath, Status: d.Status,
		CreatedAt: d.CreatedAt, UpdatedAt: d.UpdatedAt, QuestionCounts: counts}
}

func (s *Service) ListDocuments(ctx context.Context) ([]DocumentView, error) {
	qs := s.reader()
	docs, err := qs.ListDocuments(ctx)
	if err != nil {
		return nil, err
	}
	rows, err := qs.DocumentQuestionCounts(ctx)
	if err != nil {
		return nil, err
	}
	byDoc := map[string]map[string]int64{}
	for _, r := range rows {
		if byDoc[r.DocumentID] == nil {
			byDoc[r.DocumentID] = map[string]int64{}
		}
		byDoc[r.DocumentID][r.Status] = r.N
	}
	out := make([]DocumentView, 0, len(docs))
	for _, d := range docs {
		out = append(out, docView(d, byDoc[d.ID]))
	}
	return out, nil
}

type ChunkView struct {
	ID          string `json:"id"`
	Seq         int64  `json:"seq"`
	HeadingPath string `json:"heading_path"`
	Status      string `json:"status"`
	Generated   bool   `json:"generated"`
	Chars       int    `json:"chars"`
}

type DocumentDetail struct {
	DocumentView
	Chunks []ChunkView `json:"chunks"`
}

func (s *Service) GetDocument(ctx context.Context, id string) (DocumentDetail, error) {
	qs := s.reader()
	d, err := qs.GetDocument(ctx, id)
	if err != nil {
		return DocumentDetail{}, notFound(err, "document")
	}
	chunks, err := qs.ListChunksByDocument(ctx, id)
	if err != nil {
		return DocumentDetail{}, err
	}
	rows, err := qs.DocumentQuestionCounts(ctx)
	if err != nil {
		return DocumentDetail{}, err
	}
	counts := map[string]int64{}
	for _, r := range rows {
		if r.DocumentID == id {
			counts[r.Status] = r.N
		}
	}
	det := DocumentDetail{DocumentView: docView(d, counts), Chunks: []ChunkView{}}
	for _, c := range chunks {
		det.Chunks = append(det.Chunks, ChunkView{ID: c.ID, Seq: c.Seq, HeadingPath: c.HeadingPath,
			Status: c.Status, Generated: c.GeneratedAt.Valid, Chars: len([]rune(c.Text))})
	}
	return det, nil
}

// DocumentContent is a document with its full Markdown source, for viewing online.
type DocumentContent struct {
	DocumentView
	Content string `json:"content"`
}

// GetDocumentContent returns the stored source text of a document. Kept apart from
// GetDocument so the detail drawer, which reloads often, does not carry the whole file.
func (s *Service) GetDocumentContent(ctx context.Context, id string) (DocumentContent, error) {
	d, err := s.reader().GetDocument(ctx, id)
	if err != nil {
		return DocumentContent{}, notFound(err, "document")
	}
	return DocumentContent{DocumentView: docView(d, nil), Content: d.Content}, nil
}

// RetryDocument requeues every failed job of a document.
func (s *Service) RetryDocument(ctx context.Context, id string) (int64, error) {
	if _, err := s.reader().GetDocument(ctx, id); err != nil {
		return 0, notFound(err, "document")
	}
	now := nowMs()
	var n int64
	err := s.DB.WithTx(ctx, func(tx *sql.Tx) error {
		qs := store.New(tx)
		var err error
		n, err = qs.RetryFailedJobsByDocument(ctx, store.RetryFailedJobsByDocumentParams{Now: now, DocumentID: id})
		if err != nil || n == 0 {
			return err
		}
		return qs.SetDocumentStatus(ctx, store.SetDocumentStatusParams{Status: "generating", UpdatedAt: now, ID: id})
	})
	if err == nil && n > 0 {
		s.Queue.Notify()
		s.publishDoc(id, "generating")
	}
	return n, err
}

func (s *Service) RetryJob(ctx context.Context, id string) error {
	j, err := s.reader().GetJob(ctx, id)
	if err != nil {
		return notFound(err, "job")
	}
	now := nowMs()
	return s.DB.WithTx(ctx, func(tx *sql.Tx) error {
		qs := store.New(tx)
		n, err := qs.RetryFailedJob(ctx, store.RetryFailedJobParams{Now: now, ID: id})
		if err != nil {
			return err
		}
		if n == 0 {
			return invalid("only failed jobs can be retried")
		}
		if j.DocumentID != "" {
			if err := qs.SetDocumentStatus(ctx, store.SetDocumentStatusParams{Status: "generating", UpdatedAt: now, ID: j.DocumentID}); err != nil {
				return err
			}
		}
		s.Queue.Notify()
		return nil
	})
}

type JobView struct {
	ID          string `json:"id"`
	Type        string `json:"type"`
	DocumentID  string `json:"document_id"`
	Status      string `json:"status"`
	Attempts    int64  `json:"attempts"`
	MaxAttempts int64  `json:"max_attempts"`
	LastError   string `json:"last_error"`
	RunAt       int64  `json:"run_at"`
	CreatedAt   int64  `json:"created_at"`
	UpdatedAt   int64  `json:"updated_at"`
}

func (s *Service) ListJobs(ctx context.Context, status, documentID string, limit int) ([]JobView, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	var st, doc any
	if status != "" {
		st = status
	}
	if documentID != "" {
		doc = documentID
	}
	rows, err := s.reader().ListJobs(ctx, store.ListJobsParams{Status: st, DocumentID: doc, PageLimit: int64(limit)})
	if err != nil {
		return nil, err
	}
	out := make([]JobView, 0, len(rows))
	for _, j := range rows {
		out = append(out, JobView{ID: j.ID, Type: j.Type, DocumentID: j.DocumentID, Status: j.Status,
			Attempts: j.Attempts, MaxAttempts: j.MaxAttempts, LastError: j.LastError, RunAt: j.RunAt,
			CreatedAt: j.CreatedAt, UpdatedAt: j.UpdatedAt})
	}
	return out, nil
}

func (s *Service) publishDoc(id, status string) {
	if s.Hub != nil {
		s.Hub.Publish(events.Event{Type: "document", ID: id, DocumentID: id, Status: status})
	}
}

// refreshDocumentStatus settles a document once none of its jobs are pending
// or running: "failed" if any job failed, otherwise "review".
func (s *Service) refreshDocumentStatus(ctx context.Context, docID string) {
	var status string
	err := s.DB.WithTx(ctx, func(tx *sql.Tx) error {
		qs := store.New(tx)
		active, err := qs.CountActiveJobsByDocument(ctx, docID)
		if err != nil || active > 0 {
			return err
		}
		failed, err := qs.CountJobsByDocumentAndStatus(ctx, store.CountJobsByDocumentAndStatusParams{DocumentID: docID, Status: "failed"})
		if err != nil {
			return err
		}
		status = "review"
		if failed > 0 {
			status = "failed"
		}
		return qs.SetDocumentStatus(ctx, store.SetDocumentStatusParams{Status: status, UpdatedAt: nowMs(), ID: docID})
	})
	if err != nil {
		s.Log.Error("refresh document status", "document", docID, "err", err)
		return
	}
	if status != "" {
		s.publishDoc(docID, status)
	}
}
