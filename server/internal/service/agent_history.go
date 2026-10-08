package service

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"math"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/chlu-ux/quizmind/server/internal/agent"
	"github.com/chlu-ux/quizmind/server/internal/llm"
	"github.com/chlu-ux/quizmind/server/internal/store"
)

// ErrConflict means the request clashes with one already running (a second answer in a conversation
// that is still being answered).
var ErrConflict = errors.New("conflict")

// agentTitleRunes is how much of the first question becomes the conversation's title.
const agentTitleRunes = 30

// agentEmptyConversationTTL is how long a conversation row nobody spoke in may linger.
const agentEmptyConversationTTL = 24 * time.Hour

// AgentUserMessage is the one new message of a stored conversation; the earlier ones are read from
// the database.
type AgentUserMessage struct {
	Text          string   `json:"text"`
	AttachmentIDs []string `json:"attachment_ids"`
}

// normalizeAgentHistory turns stored messages into the history the model is given: answers with
// nothing in them (a failed or stopped one) are left out, neighbours with the same role are joined
// so roles alternate, the oldest messages are dropped until the request fits what the assistant
// accepts, and the first message is the user's. The same rules as the apps used when they sent the
// history themselves.
func normalizeAgentHistory(in []AgentMessage) []AgentMessage {
	var out []AgentMessage
	for _, m := range in {
		text := strings.TrimSpace(m.Content)
		if text == "" {
			continue
		}
		if n := len(out); n > 0 && out[n-1].Role == m.Role {
			out[n-1].Content += "\n\n" + text
			out[n-1].imageIDs = append(out[n-1].imageIDs, m.imageIDs...)
		} else {
			out = append(out, AgentMessage{Role: m.Role, Content: text, imageIDs: m.imageIDs})
		}
	}
	chars := func() int {
		n := 0
		for _, m := range out {
			n += utf8.RuneCountInString(m.Content)
		}
		return n
	}
	for len(out) > agentMaxMessages || (len(out) > 1 && chars() > agentMaxChars) {
		out = out[1:]
	}
	for len(out) > 0 && out[0].Role != "user" {
		out = out[1:]
	}
	return out
}

// agentTitle is the first words of a question, on one line.
func agentTitle(text string) string {
	r := []rune(strings.Join(strings.Fields(text), " "))
	if len(r) > agentTitleRunes {
		r = append(r[:agentTitleRunes:agentTitleRunes], '…')
	}
	return string(r)
}

type storedChat struct {
	id, mode  string
	files     []agent.File // the text files the assistant may read
	hasImages bool         // some message in the history shows a picture
}

// imageIDsOf returns the pictures among the files a message carried.
func (cf chatFiles) imageIDsOf(ids []string) []string {
	var out []string
	for _, id := range ids {
		if r, ok := cf.byID[id]; ok && r.Kind == "image" {
			out = append(out, id)
		}
	}
	return out
}

// attachImages loads the pictures of the history for the model. A conversation holds few enough that
// each question can show them all again; when the model cannot look at pictures (it was switched
// since), the messages that carried them get a line in their text instead, so the model still knows
// a picture was there. It reports whether any picture is shown.
func (s *Service) attachImages(ctx context.Context, msgs []AgentMessage, cf chatFiles, vision bool) (bool, error) {
	shown := false
	for i := range msgs {
		m := &msgs[i]
		for _, id := range m.imageIDs {
			if !vision {
				m.Content += "\n（一张图片：" + cf.byID[id].Name + "，现在的模型看不了图片）"
				continue
			}
			a, err := s.reader().GetAgentAttachment(ctx, id)
			if err != nil {
				return false, err
			}
			m.images = append(m.images, llm.Block{Kind: llm.BlockImage, MediaType: a.Mime, Data: a.Data})
			shown = true
		}
	}
	return shown, nil
}

// prepareStoredChat reads the conversation's history from the database and puts it, with the new
// message, into in.Messages, so the request can be checked and answered like one that carried its
// own history. It does not write anything.
func (s *Service) prepareStoredChat(ctx context.Context, in AgentChatRequest) (AgentChatRequest, storedChat, error) {
	if in.ConversationID == "" || len(in.ConversationID) > agentIDMax {
		return in, storedChat{}, invalid("conversation_id is required (at most %d characters)", agentIDMax)
	}
	if strings.TrimSpace(in.Message.Text) == "" {
		return in, storedChat{}, invalid("message.text is required")
	}
	vision := s.agentVision(ctx)
	files, err := s.loadChatFiles(ctx, in.ConversationID, in.Message.AttachmentIDs, vision)
	if err != nil {
		return in, storedChat{}, err
	}
	mode := in.Mode
	var history []AgentMessage
	conv, err := s.reader().GetAgentConversation(ctx, in.ConversationID)
	switch {
	case err == nil:
		// An app that names no mode wants the whole assistant, whatever an older version of this
		// conversation was; one that names a mode gets exactly that.
		switch {
		case mode == "":
			mode = agent.ModeCreate
		case mode != conv.Mode:
			return in, storedChat{}, invalid("this is a %s conversation; start a new one for %s", conv.Mode, mode)
		}
		rows, err := s.reader().ListAgentMessages(ctx, conv.ID)
		if err != nil {
			return in, storedChat{}, err
		}
		for _, r := range rows {
			m := AgentMessage{Role: r.Role, Content: r.Text}
			if r.Role == "user" {
				var ids []string
				_ = json.Unmarshal([]byte(r.AttachmentIds), &ids)
				m.Content += files.fileNote(ids)
				m.imageIDs = files.imageIDsOf(ids)
			}
			history = append(history, m)
		}
	case errors.Is(err, sql.ErrNoRows):
		if mode == "" {
			mode = agent.ModeCreate
		}
	default:
		return in, storedChat{}, err
	}
	in.Mode = mode
	// A question whose answer never came (or came empty) is joined with the new one, so roles still alternate.
	in.Messages = normalizeAgentHistory(append(history, AgentMessage{Role: "user", Content: in.Message.Text + files.fileNote(in.Message.AttachmentIDs),
		imageIDs: files.imageIDsOf(in.Message.AttachmentIDs)}))
	hasImages, err := s.attachImages(ctx, in.Messages, files, vision)
	if err != nil {
		return in, storedChat{}, err
	}
	return in, storedChat{id: in.ConversationID, mode: mode, files: files.files, hasImages: hasImages}, nil
}

// lockAgentConversation allows one answer at a time per conversation; two would interleave in the history.
func (s *Service) lockAgentConversation(id string) (unlock func(), err error) {
	s.agentMu.Lock()
	defer s.agentMu.Unlock()
	if s.agentActive == nil {
		s.agentActive = map[string]bool{}
	}
	if s.agentActive[id] {
		return nil, ErrConflict
	}
	s.agentActive[id] = true
	return func() {
		s.agentMu.Lock()
		defer s.agentMu.Unlock()
		delete(s.agentActive, id)
	}, nil
}

// saveAgentQuestion records the learner's message, creating the conversation on the first one.
func (s *Service) saveAgentQuestion(ctx context.Context, in AgentChatRequest, mode string) error {
	now := nowMs()
	return s.DB.WithTx(ctx, func(tx *sql.Tx) error {
		qs := store.New(tx)
		var questionID string
		if in.Context.Question != nil {
			questionID = in.Context.Question.ID
		}
		if err := qs.UpsertAgentConversation(ctx, store.UpsertAgentConversationParams{
			ID: in.ConversationID, Mode: mode, DeviceID: in.DeviceID, BankID: in.Context.BankID,
			LessonID: in.Context.LessonID, QuestionID: questionID, CreatedAt: now, UpdatedAt: now,
		}); err != nil {
			return err
		}
		if conv, err := qs.GetAgentConversation(ctx, in.ConversationID); err != nil {
			return err
		} else if conv.Title == "" {
			if err := qs.SetAgentConversationTitle(ctx, store.SetAgentConversationTitleParams{
				Title: agentTitle(in.Message.Text), ID: in.ConversationID,
			}); err != nil {
				return err
			}
		}
		ids, _ := json.Marshal(in.Message.AttachmentIDs)
		if in.Message.AttachmentIDs == nil {
			ids = []byte("[]")
		}
		msgID, err := qs.InsertAgentMessage(ctx, store.InsertAgentMessageParams{
			ConversationID: in.ConversationID, Role: "user", Text: in.Message.Text, Tools: "[]", DraftIds: "[]",
			AttachmentIds: string(ids), CreatedAt: now,
		})
		if err != nil {
			return err
		}
		for _, id := range in.Message.AttachmentIDs {
			n, err := qs.MarkAgentAttachmentSent(ctx, store.MarkAgentAttachmentSentParams{
				MessageID: sql.NullInt64{Int64: msgID, Valid: true}, ID: id, ConversationID: in.ConversationID,
			})
			if err != nil {
				return err
			}
			if n == 0 { // cleaned away, or sent by another request, since the check
				return invalid("文件 %q 已经不能用了，请重新上传", id)
			}
		}
		return nil
	})
}

type toolRow struct {
	ID     string `json:"id"`
	Label  string `json:"label"`
	Status string `json:"status"`
}

// answerLog collects what the learner saw of an answer, to store it.
type answerLog struct {
	text    strings.Builder
	tools   []toolRow
	drafts  []string
	note    string
	errText string
	ended   bool // a done or error event came
}

func (a *answerLog) observe(ev agent.Event) {
	switch e := ev.(type) {
	case agent.Delta:
		a.text.WriteString(e.Text)
	case agent.ToolEvent:
		row := toolRow{ID: e.ID, Label: e.Label, Status: e.Status}
		for i := range a.tools {
			if a.tools[i].ID == e.ID {
				a.tools[i] = row
				return
			}
		}
		a.tools = append(a.tools, row)
	case agent.Drafts:
		for _, d := range e.Drafts {
			seen := false
			for _, id := range a.drafts {
				seen = seen || id == d.DraftID
			}
			if !seen {
				a.drafts = append(a.drafts, d.DraftID)
			}
		}
	case agent.Done:
		a.ended = true
		switch e.Stop {
		case "max_tokens":
			a.note = "回答太长，被截断了"
		case "max_rounds":
			a.note = "查了很多资料，只能先答到这里"
		}
	case agent.Error:
		a.ended = true
		a.errText = e.Message
	}
}

func (a *answerLog) empty() bool {
	return a.text.Len() == 0 && len(a.tools) == 0 && len(a.drafts) == 0 && a.note == "" && a.errText == ""
}

// saveAgentAnswer stores the answer. It runs after the request is over, so it must not depend on
// the request's context (the client may have left).
func (s *Service) saveAgentAnswer(conversationID string, a *answerLog) error {
	if a.empty() {
		return nil
	}
	for i := range a.tools {
		if a.tools[i].Status == "running" { // a lookup that never reported back is not still running
			a.tools[i].Status = "done"
		}
	}
	tools, _ := json.Marshal(a.tools)
	if a.tools == nil {
		tools = []byte("[]")
	}
	drafts, _ := json.Marshal(a.drafts)
	if a.drafts == nil {
		drafts = []byte("[]")
	}
	ctx := context.Background()
	now := nowMs()
	return s.DB.WithTx(ctx, func(tx *sql.Tx) error {
		qs := store.New(tx)
		if _, err := qs.InsertAgentMessage(ctx, store.InsertAgentMessageParams{
			ConversationID: conversationID, Role: "assistant", Text: a.text.String(), Tools: string(tools),
			DraftIds: string(drafts), AttachmentIds: "[]", Note: a.note, Error: a.errText, CreatedAt: now,
		}); err != nil {
			return err
		}
		return qs.TouchAgentConversation(ctx, store.TouchAgentConversationParams{UpdatedAt: now, ID: conversationID})
	})
}

// cleanAgentHistory removes what an abandoned upload or request left behind.
func (s *Service) cleanAgentHistory(ctx context.Context) {
	if n, err := store.New(s.DB.Write).DeleteStaleAgentAttachments(ctx, time.Now().Add(-agentUnsentFileTTL).UnixMilli()); err != nil {
		s.Log.Warn("clean agent files", "err", err)
	} else if n > 0 {
		s.Log.Info("removed unsent agent files", "count", n)
	}
	n, err := store.New(s.DB.Write).DeleteEmptyAgentConversations(ctx, time.Now().Add(-agentEmptyConversationTTL).UnixMilli())
	if err != nil {
		s.Log.Warn("clean agent conversations", "err", err)
	} else if n > 0 {
		s.Log.Info("removed empty agent conversations", "count", n)
	}
}

// ---- reading and deleting history ----

type AgentConversationItem struct {
	ID            string `json:"id"`
	Mode          string `json:"mode"`
	Title         string `json:"title"`
	BankID        string `json:"bank_id"`
	LessonID      string `json:"lesson_id"`
	QuestionID    string `json:"question_id"`
	MessageCount  int64  `json:"message_count"`
	PendingDrafts int64  `json:"pending_drafts"`
	UpdatedAt     int64  `json:"updated_at"`
}

type AgentConversationPage struct {
	Items   []AgentConversationItem `json:"items"`
	HasMore bool                    `json:"has_more"`
}

// ListAgentConversations lists conversations, newest first; before is the updated_at of the last one
// of the previous page (zero for the first page).
func (s *Service) ListAgentConversations(ctx context.Context, token, mode string, before int64, limit int) (AgentConversationPage, error) {
	if err := s.checkAppToken(ctx, token); err != nil {
		return AgentConversationPage{}, err
	}
	if mode != "" && mode != agent.ModeLearn && mode != agent.ModeCreate {
		return AgentConversationPage{}, invalid("mode must be learn or create")
	}
	if limit <= 0 || limit > 100 {
		limit = 30
	}
	if before <= 0 {
		before = math.MaxInt64
	}
	var m any
	if mode != "" {
		m = mode
	}
	rows, err := s.reader().ListAgentConversations(ctx, store.ListAgentConversationsParams{
		Before: before, Mode: m, PageLimit: int64(limit) + 1,
	})
	if err != nil {
		return AgentConversationPage{}, err
	}
	page := AgentConversationPage{Items: []AgentConversationItem{}}
	for i, r := range rows {
		if i == limit {
			page.HasMore = true
			break
		}
		page.Items = append(page.Items, AgentConversationItem{ID: r.ID, Mode: r.Mode, Title: r.Title, BankID: r.BankID,
			LessonID: r.LessonID, QuestionID: r.QuestionID, MessageCount: r.MessageCount, PendingDrafts: r.PendingDrafts,
			UpdatedAt: r.UpdatedAt})
	}
	return page, nil
}

// AgentDraftView is a draft with what became of it.
type AgentDraftView struct {
	agent.Draft
	// Phase is pending (still waiting), accepted (sent to review, maybe published) or discarded
	// (thrown away by the learner, replaced, or left too long).
	Phase string `json:"phase"`
}

func draftPhase(status string) string {
	switch status {
	case "draft":
		return "pending"
	case "rejected", "retired":
		return "discarded"
	default:
		return "accepted"
	}
}

type AgentMessageView struct {
	ID          int64            `json:"id"`
	Role        string           `json:"role"`
	Text        string           `json:"text"`
	Tools       []toolRow        `json:"tools"`
	Drafts      []AgentDraftView `json:"drafts"`
	Attachments []AttachmentView `json:"attachments"`
	Note        string           `json:"note"`
	Error       string           `json:"error"`
	CreatedAt   int64            `json:"created_at"`
}

type AgentConversationDetail struct {
	ID         string             `json:"id"`
	Mode       string             `json:"mode"`
	Title      string             `json:"title"`
	BankID     string             `json:"bank_id"`
	LessonID   string             `json:"lesson_id"`
	QuestionID string             `json:"question_id"`
	UpdatedAt  int64              `json:"updated_at"`
	Messages   []AgentMessageView `json:"messages"`
}

func (s *Service) GetAgentConversation(ctx context.Context, token, id string) (AgentConversationDetail, error) {
	if err := s.checkAppToken(ctx, token); err != nil {
		return AgentConversationDetail{}, err
	}
	q := s.reader()
	conv, err := q.GetAgentConversation(ctx, id)
	if err != nil {
		return AgentConversationDetail{}, notFound(err, "conversation")
	}
	rows, err := q.ListAgentMessages(ctx, id)
	if err != nil {
		return AgentConversationDetail{}, err
	}
	draftRows, err := q.ListConversationDrafts(ctx, id)
	if err != nil {
		return AgentConversationDetail{}, err
	}
	drafts := map[string]AgentDraftView{}
	for _, r := range draftRows {
		d := buildAgentDraft(r.ID, r.DraftLessonID, r.Type, r.Stem, r.Options, r.Answer, r.Tags, r.Explanation, r.SourceQuote,
			r.Difficulty, r.Verified != 0)
		drafts[r.ID] = AgentDraftView{Draft: d, Phase: draftPhase(r.Status)}
	}
	atts, err := s.attachmentViews(ctx, id)
	if err != nil {
		return AgentConversationDetail{}, err
	}
	out := AgentConversationDetail{ID: conv.ID, Mode: conv.Mode, Title: conv.Title, BankID: conv.BankID, LessonID: conv.LessonID,
		QuestionID: conv.QuestionID, UpdatedAt: conv.UpdatedAt, Messages: make([]AgentMessageView, 0, len(rows))}
	for _, r := range rows {
		m := AgentMessageView{ID: r.ID, Role: r.Role, Text: r.Text, Note: r.Note, Error: r.Error, CreatedAt: r.CreatedAt,
			Tools: []toolRow{}, Drafts: []AgentDraftView{}, Attachments: []AttachmentView{}}
		_ = json.Unmarshal([]byte(r.Tools), &m.Tools)
		var ids []string
		_ = json.Unmarshal([]byte(r.DraftIds), &ids)
		for _, did := range ids {
			if d, ok := drafts[did]; ok {
				m.Drafts = append(m.Drafts, d)
			}
		}
		ids = nil
		_ = json.Unmarshal([]byte(r.AttachmentIds), &ids)
		for _, aid := range ids {
			if a, ok := atts[aid]; ok {
				m.Attachments = append(m.Attachments, a)
			}
		}
		out.Messages = append(out.Messages, m)
	}
	return out, nil
}

// RenameAgentConversation changes the title shown in the list.
func (s *Service) RenameAgentConversation(ctx context.Context, token, id, title string) error {
	if err := s.checkAppToken(ctx, token); err != nil {
		return err
	}
	title = agentTitle(title)
	if title == "" {
		return invalid("title is required")
	}
	if _, err := s.reader().GetAgentConversation(ctx, id); err != nil {
		return notFound(err, "conversation")
	}
	return store.New(s.DB.Write).SetAgentConversationTitle(ctx, store.SetAgentConversationTitleParams{Title: title, ID: id})
}

// DeleteAgentConversation deletes a conversation with its messages and files, and discards the
// drafts nobody decided on. Questions the learner already accepted are not touched.
func (s *Service) DeleteAgentConversation(ctx context.Context, token, id string) error {
	if err := s.checkAppToken(ctx, token); err != nil {
		return err
	}
	if _, err := s.reader().GetAgentConversation(ctx, id); err != nil {
		return notFound(err, "conversation")
	}
	unlock, err := s.lockAgentConversation(id)
	if err != nil {
		return err // an answer is being written
	}
	defer unlock()
	now := nowMs()
	return s.DB.WithTx(ctx, func(tx *sql.Tx) error {
		qs := store.New(tx)
		if _, err := qs.RejectConversationDrafts(ctx, store.RejectConversationDraftsParams{UpdatedAt: now, ConversationID: id}); err != nil {
			return err
		}
		if err := deleteAttachments(ctx, tx, id); err != nil {
			return err
		}
		if err := qs.DeleteAgentMessages(ctx, id); err != nil {
			return err
		}
		return qs.DeleteAgentConversation(ctx, id)
	})
}
