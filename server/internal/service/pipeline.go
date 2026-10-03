package service

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/chlu-ux/quizmind/server/internal/jobs"
	"github.com/chlu-ux/quizmind/server/internal/llm"
	"github.com/chlu-ux/quizmind/server/internal/pipeline"
	"github.com/chlu-ux/quizmind/server/internal/store"
)

type documentPayload struct {
	DocumentID string `json:"document_id"`
}

type chunkPayload struct {
	ChunkID string `json:"chunk_id"`
}

// handleChunkDocument splits the document and reconciles the result with the
// chunks stored from earlier imports, so unchanged chunks keep their questions
// and only new or changed chunks are sent to the model.
func (s *Service) handleChunkDocument(ctx context.Context, job store.Job) error {
	var p documentPayload
	if err := json.Unmarshal([]byte(job.Payload), &p); err != nil {
		return jobs.Permanent(fmt.Errorf("bad payload: %w", err))
	}
	doc, err := s.reader().GetDocument(ctx, p.DocumentID)
	if errors.Is(err, sql.ErrNoRows) {
		return jobs.Permanent(fmt.Errorf("document %s no longer exists", p.DocumentID))
	}
	if err != nil {
		return err
	}

	mdTitle, chunks := pipeline.Split(doc.Content, pipeline.ChunkOptions{
		MinChars: s.Cfg.Pipeline.ChunkMinChars,
		MaxChars: s.Cfg.Pipeline.ChunkMaxChars,
	})

	var toGenerate int
	err = s.DB.WithTx(ctx, func(tx *sql.Tx) error {
		qs := store.New(tx)
		now := nowMs()
		if err := qs.SupersedeFailedJobs(ctx, store.SupersedeFailedJobsParams{UpdatedAt: now, DocumentID: doc.ID}); err != nil {
			return err
		}
		if mdTitle != "" && mdTitle != doc.Title {
			if err := qs.SetDocumentTitle(ctx, store.SetDocumentTitleParams{Title: mdTitle, UpdatedAt: now, ID: doc.ID}); err != nil {
				return err
			}
		}
		if err := s.reconcileChunks(ctx, qs, doc.ID, chunks); err != nil {
			return err
		}
		pending, err := qs.ListChunksToGenerate(ctx, doc.ID)
		if err != nil {
			return err
		}
		for _, c := range pending {
			if _, err := s.Queue.EnqueueTx(ctx, qs, JobGenerateChunk, doc.ID, chunkPayload{ChunkID: c.ID}); err != nil {
				return err
			}
		}
		toGenerate = len(pending)
		if toGenerate > 0 {
			return qs.SetDocumentStatus(ctx, store.SetDocumentStatusParams{Status: "generating", UpdatedAt: now, ID: doc.ID})
		}
		return nil
	})
	if err != nil {
		return err
	}
	s.Log.Info("document chunked", "document", doc.ID, "chunks", len(chunks), "to_generate", toGenerate)
	if toGenerate > 0 {
		s.publishDoc(doc.ID, "generating")
		s.Queue.Notify()
	}
	return nil
}

// reconcileChunks makes the stored chunks match the freshly split ones.
//
//	same hash        -> keep the chunk (and its questions), refresh order/path
//	new hash         -> insert, to be generated
//	vanished chunk   -> if a new chunk now sits under the same heading path the
//	                    section was edited: mark it stale and its questions stale.
//	                    Otherwise the section was deleted: mark it removed and
//	                    retire its questions.
func (s *Service) reconcileChunks(ctx context.Context, qs *store.Queries, docID string, fresh []pipeline.Chunk) error {
	existing, err := qs.ListChunksByDocument(ctx, docID)
	if err != nil {
		return err
	}
	byHash := map[string]store.Chunk{}
	for _, c := range existing {
		byHash[c.ContentHash] = c
	}

	keep := map[string]bool{}
	newPaths := map[string]bool{}
	for _, c := range fresh {
		keep[c.Hash] = true
		if old, ok := byHash[c.Hash]; ok {
			if err := qs.UpdateChunk(ctx, store.UpdateChunkParams{
				Seq: int64(c.Seq), HeadingPath: c.HeadingPath, Status: "active", ID: old.ID,
			}); err != nil {
				return err
			}
			continue
		}
		newPaths[c.HeadingPath] = true
		if err := qs.InsertChunk(ctx, store.InsertChunkParams{
			ID: newID(), DocumentID: docID, Seq: int64(c.Seq), HeadingPath: c.HeadingPath,
			Text: c.Text, ContentHash: c.Hash, Status: "active",
		}); err != nil {
			return err
		}
	}

	for _, old := range existing {
		if keep[old.ContentHash] || old.Status != "active" {
			continue
		}
		chunkStatus, qStatus := "removed", "retired"
		if newPaths[old.HeadingPath] {
			chunkStatus, qStatus = "stale", "stale"
		}
		if err := qs.UpdateChunk(ctx, store.UpdateChunkParams{
			Seq: old.Seq, HeadingPath: old.HeadingPath, Status: chunkStatus, ID: old.ID,
		}); err != nil {
			return err
		}
		if err := s.setChunkQuestionsStatus(ctx, qs, old.ID, qStatus, "chunk "+chunkStatus+" after document re-import"); err != nil {
			return err
		}
	}
	return nil
}

// setChunkQuestionsStatus moves a chunk's live questions to status. Questions
// that were published get a fresh sync_seq so clients learn they are gone.
func (s *Service) setChunkQuestionsStatus(ctx context.Context, qs *store.Queries, chunkID, status, note string) error {
	rows, err := qs.ListQuestionIDsByChunk(ctx, sql.NullString{String: chunkID, Valid: true})
	if err != nil {
		return err
	}
	for _, r := range rows {
		seq := sql.NullInt64{}
		if r.Status == "published" {
			n, err := qs.NextSyncSeq(ctx)
			if err != nil {
				return err
			}
			seq = sql.NullInt64{Int64: n, Valid: true}
		}
		if err := qs.SetQuestionStatus(ctx, store.SetQuestionStatusParams{
			Status: status, ReviewNote: note, SyncSeq: seq, UpdatedAt: nowMs(), ID: r.ID,
		}); err != nil {
			return err
		}
	}
	return nil
}

// handleGenerateChunk asks the generator model for questions about one chunk,
// validates and de-duplicates them, and stores the survivors for review.
func (s *Service) handleGenerateChunk(ctx context.Context, job store.Job) error {
	var p chunkPayload
	if err := json.Unmarshal([]byte(job.Payload), &p); err != nil {
		return jobs.Permanent(fmt.Errorf("bad payload: %w", err))
	}
	qs := s.reader()
	chunk, err := qs.GetChunk(ctx, p.ChunkID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil // chunk was deleted: nothing to do
	}
	if err != nil {
		return err
	}
	if chunk.Status != "active" || chunk.GeneratedAt.Valid {
		return nil // superseded, or already generated by an earlier job
	}
	doc, err := qs.GetDocument(ctx, chunk.DocumentID)
	if err != nil {
		return err
	}

	client, err := s.LLM.For(llm.RoleGenerator)
	if err != nil {
		return jobs.Permanent(err)
	}
	gen := &pipeline.Generator{LLM: client, PerChunk: s.Cfg.Pipeline.QuestionsPerChunk}
	candidates, _, err := gen.Generate(llm.WithJobID(ctx, job.ID), chunk.HeadingPath, chunk.Text)
	switch {
	case errors.Is(err, llm.ErrBudgetExceeded):
		return jobs.Defer(err, 30*time.Minute)
	case errors.Is(err, llm.ErrRefused), errors.Is(err, llm.ErrTruncated):
		return jobs.Permanent(err)
	case err != nil:
		return err
	}

	live, err := qs.ListLiveQuestionsByBank(ctx, doc.BankID)
	if err != nil {
		return err
	}
	existing := make([]pipeline.Existing, 0, len(live))
	for _, q := range live {
		var opts []string
		_ = json.Unmarshal([]byte(q.Options), &opts)
		existing = append(existing, pipeline.Existing{ID: q.ID, Hash: q.ContentHash, Stem: q.Stem, Options: opts})
	}
	dedupe := pipeline.NewDeduper(existing, s.Cfg.Pipeline.DedupeThreshold)

	rows := make([]store.InsertQuestionParams, 0, len(candidates))
	for _, cand := range candidates {
		row := s.buildQuestionRow(doc.BankID, chunk, client.Model(), cand, dedupe)
		rows = append(rows, row)
	}

	return s.DB.WithTx(ctx, func(tx *sql.Tx) error {
		qs := store.New(tx)
		n, err := qs.MarkChunkGenerated(ctx, store.MarkChunkGeneratedParams{
			GeneratedAt: sql.NullInt64{Int64: nowMs(), Valid: true}, ID: chunk.ID,
		})
		if err != nil {
			return err
		}
		if n == 0 {
			return nil // a concurrent job finished first; drop our copy
		}
		for _, r := range rows {
			if err := qs.InsertQuestion(ctx, r); err != nil {
				return err
			}
		}
		return nil
	})
}

// buildQuestionRow turns one model candidate into a row. Candidates that fail
// validation or duplicate an existing question are kept as "rejected" with the
// reason, so pass rates are visible and nothing silently disappears.
func (s *Service) buildQuestionRow(bankID string, chunk store.Chunk, model string,
	cand pipeline.GeneratedQuestion, dedupe *pipeline.Deduper) store.InsertQuestionParams {

	id := newID()
	now := nowMs()
	row := store.InsertQuestionParams{
		ID: id, BankID: bankID, ChunkID: sql.NullString{String: chunk.ID, Valid: true},
		GenModel: model, GenPromptVersion: pipeline.PromptVersion, CreatedAt: now, UpdatedAt: now,
	}

	v, err := pipeline.ValidateQuestion(cand, chunk.Text)
	if err != nil {
		row.Type = pipeline.TypeSingle
		if cand.Type == pipeline.TypeJudge {
			row.Type = pipeline.TypeJudge
		}
		row.Stem = cand.Stem
		row.Options = jsonArray(cand.Options)
		row.Answer = jsonArray([]int{cand.AnswerIndex})
		row.Explanation = cand.Explanation
		row.Difficulty = 3
		row.Tags = jsonArray(cand.Tags)
		row.SourceQuote = cand.SourceQuote
		row.Status = "rejected"
		row.ReviewNote = "auto: " + err.Error()
		row.ContentHash = pipeline.ContentHash(cand.Stem, cand.Options)
		return row
	}

	row.Type = v.Type
	row.Stem = v.Stem
	row.Options = jsonArray(v.Options)
	row.Answer = jsonArray([]int{v.AnswerIndex})
	row.Explanation = v.Explanation
	row.Difficulty = int64(v.Difficulty)
	row.Tags = jsonArray(v.Tags)
	row.SourceQuote = v.SourceQuote
	row.ContentHash = v.Hash

	if other, dup := dedupe.Check(id, v); dup {
		row.Status = "rejected"
		row.ReviewNote = "auto: duplicate of question " + other
		return row
	}
	// No independent validator yet (planned for M3): everything that passes the
	// rules waits for a human.
	row.Status = "needs_review"
	return row
}
