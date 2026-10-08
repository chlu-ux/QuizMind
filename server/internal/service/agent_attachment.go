package service

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/chlu-ux/quizmind/server/internal/agent"
	"github.com/chlu-ux/quizmind/server/internal/store"
)

// Limits of the files a learner gives the assistant.
const (
	MaxAgentTextBytes = 512 << 10 // an uploaded text file
	agentMaxTextChars = 120000    // what is left of it as text
	agentMaxFiles     = 8         // per conversation
	agentMaxPerMsg    = 4         // per message
	// agentUnsentFileTTL is how long an uploaded file may wait for the message that carries it.
	agentUnsentFileTTL = 24 * time.Hour
)

// agentTextExts are the file types taken as text. The extension only selects the kind of file; the
// bytes must still be valid UTF-8 text.
var agentTextExts = map[string]string{
	".md": "text/markdown", ".markdown": "text/markdown", ".txt": "text/plain",
	".csv": "text/csv", ".json": "application/json", ".log": "text/plain",
}

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

func attachmentView(id, kind, name, mime string, size, chars, width, height int64) AttachmentView {
	return AttachmentView{ID: id, Kind: kind, Name: name, Mime: mime, Size: size, Chars: chars, Width: width, Height: height}
}

// UploadAgentAttachment stores a text file for a conversation (which need not exist yet: it is
// created with the first message). The file waits to be sent with a message.
func (s *Service) UploadAgentAttachment(ctx context.Context, token, conversationID, filename string, data []byte) (AttachmentView, error) {
	if err := s.checkAppToken(ctx, token); err != nil {
		return AttachmentView{}, err
	}
	if conversationID == "" || len(conversationID) > agentIDMax {
		return AttachmentView{}, invalid("conversation_id is required (at most %d characters)", agentIDMax)
	}
	name := agentFileName(filename)
	mime, ok := agentTextExts[strings.ToLower(filepath.Ext(name))]
	if !ok {
		return AttachmentView{}, invalid("不支持这种文件，可以上传 .md .markdown .txt .csv .json .log 文本文件")
	}
	if len(data) == 0 {
		return AttachmentView{}, invalid("这个文件是空的")
	}
	if len(data) > MaxAgentTextBytes {
		return AttachmentView{}, invalid("文件太大了（超过 %d KB），请截取需要的部分再上传", MaxAgentTextBytes>>10)
	}
	text, err := agentFileText(data)
	if err != nil {
		return AttachmentView{}, err
	}
	chars := utf8.RuneCountInString(text)
	if chars > agentMaxTextChars {
		return AttachmentView{}, invalid("文件有 %d 字，超过了 %d 字的上限，请截取需要的部分再上传", chars, agentMaxTextChars)
	}

	s.cleanAgentHistory(ctx)
	existing, err := s.reader().ListConversationAttachments(ctx, conversationID)
	if err != nil {
		return AttachmentView{}, err
	}
	if len(existing) >= agentMaxFiles {
		return AttachmentView{}, invalid("一场对话最多 %d 个文件", agentMaxFiles)
	}
	id := newID()
	if err := store.New(s.DB.Write).InsertAgentAttachment(ctx, store.InsertAgentAttachmentParams{
		ID: id, ConversationID: conversationID, Kind: "text", Name: name, Mime: mime, Size: int64(len(data)),
		Chars: int64(chars), Text: text, CreatedAt: nowMs(),
	}); err != nil {
		return AttachmentView{}, err
	}
	return attachmentView(id, "text", name, mime, int64(len(data)), int64(chars), 0, 0), nil
}

// agentFileName keeps only the last part of a name the client sent, so it is safe to show and store.
func agentFileName(s string) string {
	s = strings.ReplaceAll(s, `\`, "/")
	if i := strings.LastIndex(s, "/"); i >= 0 {
		s = s[i+1:]
	}
	s = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, s)
	s = strings.TrimSpace(s)
	if r := []rune(s); len(r) > 100 {
		s = string(r[:100])
	}
	return s
}

// agentFileText checks the bytes are text and returns it without a byte-order mark and with
// Windows line endings turned into newlines.
func agentFileText(data []byte) (string, error) {
	data = bytes.TrimPrefix(data, []byte("\xef\xbb\xbf"))
	if !utf8.Valid(data) || bytes.IndexByte(data, 0) >= 0 {
		return "", invalid("这个文件不是 UTF-8 文本，请另存为 UTF-8 编码的文本文件再上传")
	}
	text := strings.ReplaceAll(string(data), "\r\n", "\n")
	if strings.TrimSpace(text) == "" {
		return "", invalid("这个文件里没有文字")
	}
	return text, nil
}

// GetAgentAttachment returns a file by id.
func (s *Service) GetAgentAttachment(ctx context.Context, token, id string) (store.AgentAttachment, error) {
	if err := s.checkAppToken(ctx, token); err != nil {
		return store.AgentAttachment{}, err
	}
	a, err := s.reader().GetAgentAttachment(ctx, id)
	if err != nil {
		return store.AgentAttachment{}, notFound(err, "attachment")
	}
	return a, nil
}

// DeleteAgentAttachment removes a file that no message has carried yet.
func (s *Service) DeleteAgentAttachment(ctx context.Context, token, id string) error {
	if err := s.checkAppToken(ctx, token); err != nil {
		return err
	}
	a, err := s.reader().GetAgentAttachment(ctx, id)
	if err != nil {
		return notFound(err, "attachment")
	}
	if a.MessageID.Valid {
		return invalid("这个文件已经随消息发出，不能单独删除；删除整场对话时才会一起删掉")
	}
	_, err = store.New(s.DB.Write).DeleteUnsentAgentAttachment(ctx, id)
	return err
}

// attachmentViews returns the files of a conversation by id.
func (s *Service) attachmentViews(ctx context.Context, conversationID string) (map[string]AttachmentView, error) {
	rows, err := s.reader().ListConversationAttachments(ctx, conversationID)
	if err != nil {
		return nil, err
	}
	out := make(map[string]AttachmentView, len(rows))
	for _, r := range rows {
		out[r.ID] = attachmentView(r.ID, r.Kind, r.Name, r.Mime, r.Size, r.Chars, r.Width, r.Height)
	}
	return out, nil
}

// deleteAttachments removes a conversation's files.
func deleteAttachments(ctx context.Context, tx *sql.Tx, conversationID string) error {
	return store.New(tx).DeleteConversationAttachments(ctx, conversationID)
}

// chatFiles are the files a request may use: the ones earlier messages carried and the ones the new
// message carries.
type chatFiles struct {
	files []agent.File
	byID  map[string]store.ListConversationAttachmentsRow
}

// loadChatFiles checks the files the new message carries and returns every file of the conversation
// that has been (or is being) sent.
func (s *Service) loadChatFiles(ctx context.Context, conversationID string, newIDs []string) (chatFiles, error) {
	rows, err := s.reader().ListConversationAttachments(ctx, conversationID)
	if err != nil {
		return chatFiles{}, err
	}
	cf := chatFiles{byID: map[string]store.ListConversationAttachmentsRow{}}
	for _, r := range rows {
		cf.byID[r.ID] = r
	}
	if len(newIDs) > agentMaxPerMsg {
		return chatFiles{}, invalid("一条消息最多带 %d 个文件", agentMaxPerMsg)
	}
	sending := map[string]bool{}
	for _, id := range newIDs {
		r, ok := cf.byID[id]
		switch {
		case !ok:
			return chatFiles{}, invalid("找不到文件 %q（它可能属于别的对话，或已被清理），请重新上传", id)
		case sending[id]:
			return chatFiles{}, invalid("文件 %q 重复了", id)
		case r.MessageID.Valid:
			return chatFiles{}, invalid("文件「%s」已经随之前的消息发出了", r.Name)
		case r.Kind != "text":
			return chatFiles{}, invalid("暂时只能读取文本文件")
		}
		sending[id] = true
	}
	for _, r := range rows {
		if r.Kind == "text" && (r.MessageID.Valid || sending[r.ID]) {
			cf.files = append(cf.files, agent.File{ID: r.ID, Name: r.Name, Chars: int(r.Chars)})
		}
	}
	return cf, nil
}

// fileNote is the line added to a user's message that carried files, so the model knows which
// file "this note" means. The stored text stays what the learner typed.
func (cf chatFiles) fileNote(ids []string) string {
	var parts []string
	for _, id := range ids {
		if r, ok := cf.byID[id]; ok {
			parts = append(parts, fmt.Sprintf("%s，%d 字，id=%s", r.Name, r.Chars, r.ID))
		}
	}
	if len(parts) == 0 {
		return ""
	}
	return "\n（附件：" + strings.Join(parts, "；") + "）"
}

// agentFiles is what the assistant's read_attachment tool reads through.
type agentFiles struct {
	s *Service
	// conversation is the only conversation the files may come from.
	conversation string
}

func (f agentFiles) Text(ctx context.Context, id string) (string, error) {
	a, err := f.s.reader().GetAgentAttachment(ctx, id)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", agent.ErrNoFile
		}
		return "", err
	}
	if a.ConversationID != f.conversation || a.Kind != "text" {
		return "", agent.ErrNoFile
	}
	return a.Text, nil
}
