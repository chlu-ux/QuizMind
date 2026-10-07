package service

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"strconv"
)

// Lesson is one section of a document as the app shows it for reading: the text the questions
// of that section were generated from.
type Lesson struct {
	// ID is the chunk id; SyncQuestion.ChunkID names the lesson a question belongs to.
	ID         string `json:"id"`
	BankID     string `json:"bank_id"`
	DocumentID string `json:"document_id"`
	// The chapter: the document the section is in, and when it was added (chapters are listed in that order).
	DocumentTitle     string `json:"document_title"`
	DocumentCreatedAt int64  `json:"document_created_at"`
	Seq               int64  `json:"seq"`
	// Where the section sits in the document, e.g. "考点精讲 > 2.1 操作系统概述".
	HeadingPath string `json:"heading_path"`
	Text        string `json:"text"`
}

// LessonsPage is the whole reading library. Sections change rarely and are small, so the app
// fetches them all and skips the download when Version has not moved.
type LessonsPage struct {
	// Version changes whenever any section is added, edited, moved or removed. It is a positive
	// integer below 2^48, so it is exact as a JSON number in a browser.
	Version int64 `json:"version"`
	// True when the caller already has Version; Items is then empty.
	Unchanged bool     `json:"unchanged"`
	Items     []Lesson `json:"items"`
}

// Lessons returns every active section, or nothing but the version when [have] is already current.
func (s *Service) Lessons(ctx context.Context, have int64) (LessonsPage, error) {
	rows, err := s.reader().ListLessons(ctx)
	if err != nil {
		return LessonsPage{}, err
	}
	h := sha256.New()
	for _, r := range rows {
		// Everything the app shows, so a renamed chapter or a moved section also bumps the version.
		for _, f := range []string{r.ID, r.ContentHash, strconv.FormatInt(r.Seq, 10), r.HeadingPath, r.DocumentTitle, strconv.FormatInt(r.DocumentCreatedAt, 10)} {
			h.Write([]byte(f))
			h.Write([]byte{0})
		}
	}
	var sum [8]byte
	copy(sum[2:], h.Sum(nil)[:6])
	version := int64(binary.BigEndian.Uint64(sum[:])) | 1 // never 0, which means "nothing yet" to the app
	page := LessonsPage{Version: version, Items: []Lesson{}}
	if have == version {
		page.Unchanged = true
		return page, nil
	}
	for _, r := range rows {
		page.Items = append(page.Items, Lesson{
			ID: r.ID, BankID: r.BankID, DocumentID: r.DocumentID, DocumentTitle: r.DocumentTitle,
			DocumentCreatedAt: r.DocumentCreatedAt, Seq: r.Seq, HeadingPath: r.HeadingPath, Text: r.Text,
		})
	}
	return page, nil
}
