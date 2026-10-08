package service

import (
	"context"
	"database/sql"
)

// AttachmentView is a file a message carried, as the apps show it.
type AttachmentView struct {
	ID     string `json:"id"`
	Kind   string `json:"kind"` // text | image
	Name   string `json:"name"`
	Mime   string `json:"mime"`
	Size   int64  `json:"size"`
	Chars  int64  `json:"chars,omitempty"`
	Width  int64  `json:"width,omitempty"`
	Height int64  `json:"height,omitempty"`
}

// attachmentViews returns the files of a conversation by id. (Files arrive with phase 6.)
func (s *Service) attachmentViews(_ context.Context, _ string) (map[string]AttachmentView, error) {
	return map[string]AttachmentView{}, nil
}

// deleteAttachments removes a conversation's files. (Files arrive with phase 6.)
func deleteAttachments(_ context.Context, _ *sql.Tx, _ string) error { return nil }
