package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/chlu-ux/quizmind/server/internal/agent"
	"github.com/chlu-ux/quizmind/server/internal/llm"
)

// ErrBusy means the device already has as many conversations running as it may.
var ErrBusy = errors.New("too many conversations")

// Limits of one chat request.
const (
	agentMaxMessages    = 30
	agentMaxChars       = 24000
	agentMaxPerDevice   = 2
	agentRequestTimeout = 3 * time.Minute
	agentIDMax          = 64
)

type AgentStatus struct {
	Available bool   `json:"available"`
	Model     string `json:"model"`
	// Verified says a second model double-checks the questions the assistant writes (the validator role is bound).
	Verified bool `json:"verified"`
}

// AgentStatus tells an app whether the assistant can be used. ErrNotFound means no model is bound
// to the agent role, so the app should hide its entry points.
func (s *Service) AgentStatus(ctx context.Context, token string) (AgentStatus, error) {
	if err := s.checkAppToken(ctx, token); err != nil {
		return AgentStatus{}, err
	}
	conv, err := s.LLM.Converser(llm.RoleAgent)
	if err != nil {
		return AgentStatus{}, fmt.Errorf("%w: assistant is not configured", ErrNotFound)
	}
	_, verr := s.LLM.For(llm.RoleValidator)
	return AgentStatus{Available: true, Model: conv.Model(), Verified: verr == nil}, nil
}

type AgentMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type AgentQuestionContext struct {
	ID       string `json:"id"`
	Selected []int  `json:"selected"`
}

// AgentContext says what the learner is looking at. All parts are optional.
type AgentContext struct {
	BankID   string                `json:"bank_id"`
	LessonID string                `json:"lesson_id"`
	Question *AgentQuestionContext `json:"question"`
}

type AgentChatRequest struct {
	ConversationID string `json:"conversation_id"`
	Mode           string `json:"mode"`
	DeviceID       string `json:"device_id"`
	// Message is the new question of a conversation kept on the server; the earlier ones are read
	// from the database. Messages is the older form, in which the app sends the whole history and
	// nothing is kept; it is used only when Message is absent.
	Message  *AgentUserMessage `json:"message"`
	Messages []AgentMessage    `json:"messages"`
	Context  AgentContext      `json:"context"`
}

// AgentRun streams the answer to a validated chat request. It must be called exactly once: it
// frees the device's conversation slot when it returns.
type AgentRun func(ctx context.Context, emit func(agent.Event))

// StartAgentChat checks a chat request and returns the function that answers it. Everything that
// can fail before the answer starts fails here, so the HTTP layer can still answer with a status
// code: ErrUnauthorized, ErrNotFound (assistant not configured), ErrInvalid, ErrBusy.
func (s *Service) StartAgentChat(ctx context.Context, token string, in AgentChatRequest) (AgentRun, error) {
	if err := s.checkAppToken(ctx, token); err != nil {
		return nil, err
	}
	conv, err := s.LLM.Converser(llm.RoleAgent)
	if err != nil {
		return nil, fmt.Errorf("%w: assistant is not configured", ErrNotFound)
	}
	var stored *storedChat
	if in.Message != nil {
		var sc storedChat
		var err error
		if in, sc, err = s.prepareStoredChat(ctx, in); err != nil {
			return nil, err
		}
		stored = &sc
	}
	req, err := validateAgentRequest(in)
	if err != nil {
		return nil, err
	}
	lib := agentLibrary{s}
	if err := checkAgentContext(ctx, lib, in.Context); err != nil {
		return nil, err
	}
	unlock := func() {}
	if stored != nil {
		if unlock, err = s.lockAgentConversation(stored.id); err != nil {
			return nil, err
		}
	}
	release, err := s.acquireAgentSlot(in.DeviceID)
	if err != nil {
		unlock()
		return nil, err
	}
	// Drafts nobody decided on for a week go away; doing it here saves a background task.
	if n, err := s.RetireStaleAgentDrafts(ctx); err != nil {
		s.Log.Warn("retire stale agent drafts", "err", err)
	} else if n > 0 {
		s.Log.Info("retired stale agent drafts", "count", n)
	}
	var answer *answerLog
	if stored != nil {
		s.cleanAgentHistory(ctx)
		// The question is kept before the answer starts, so a stopped or dropped answer still leaves it.
		if err := s.saveAgentQuestion(ctx, in, stored.mode); err != nil {
			release()
			unlock()
			return nil, err
		}
		answer = &answerLog{}
	}
	a := &agent.Agent{Conv: conv, Lib: lib}
	if req.Mode == agent.ModeCreate {
		a.Drafter = agentDrafter{s: s, model: conv.Model()}
	}
	return func(ctx context.Context, emit func(agent.Event)) {
		defer unlock()
		defer release()
		outer := ctx
		ctx, cancel := context.WithTimeout(ctx, agentRequestTimeout)
		defer cancel()
		ctx = llm.WithRef(ctx, req.ConversationID, in.DeviceID)
		if answer != nil {
			inner := emit
			emit = func(ev agent.Event) {
				answer.observe(ev)
				inner(ev)
			}
			defer func() {
				if !answer.ended && errors.Is(outer.Err(), context.Canceled) {
					answer.note = "已停止" // the client left before the answer was done
				}
				if err := s.saveAgentAnswer(stored.id, answer); err != nil {
					s.Log.Error("save agent answer", "conversation", stored.id, "err", err)
				}
			}()
		}
		a.Run(ctx, req, emit)
	}, nil
}

func validateAgentRequest(in AgentChatRequest) (agent.Request, error) {
	switch in.Mode {
	case "", "learn":
	case "create":
	default:
		return agent.Request{}, invalid("mode must be learn or create")
	}
	if len(in.DeviceID) > agentIDMax || len(in.ConversationID) > agentIDMax {
		return agent.Request{}, invalid("device_id and conversation_id must be at most %d characters", agentIDMax)
	}
	n := len(in.Messages)
	if n == 0 || n > agentMaxMessages {
		return agent.Request{}, invalid("messages must hold 1 to %d messages", agentMaxMessages)
	}
	if in.Messages[0].Role != "user" || in.Messages[n-1].Role != "user" {
		return agent.Request{}, invalid("the first and last message must be from the user")
	}
	total := 0
	msgs := make([]llm.Message, 0, n)
	for i, m := range in.Messages {
		if m.Role != "user" && m.Role != "assistant" {
			return agent.Request{}, invalid("message %d: role must be user or assistant", i)
		}
		if i > 0 && m.Role == in.Messages[i-1].Role {
			return agent.Request{}, invalid("message %d: roles must alternate", i)
		}
		if strings.TrimSpace(m.Content) == "" {
			return agent.Request{}, invalid("message %d is empty", i)
		}
		total += utf8.RuneCountInString(m.Content)
		msgs = append(msgs, llm.Message{Role: m.Role, Blocks: []llm.Block{{Kind: llm.BlockText, Text: m.Content}}})
	}
	if total > agentMaxChars {
		return agent.Request{}, invalid("the messages are longer than %d characters", agentMaxChars)
	}
	id := in.ConversationID
	if id == "" {
		id = newID()
	}
	ctx := agent.Context{BankID: in.Context.BankID, LessonID: in.Context.LessonID}
	if q := in.Context.Question; q != nil {
		ctx.Question = &agent.QuestionContext{ID: q.ID, Selected: q.Selected}
	}
	mode := in.Mode
	if mode == "" {
		mode = agent.ModeLearn
	}
	return agent.Request{ConversationID: id, Mode: mode, DeviceID: in.DeviceID, Messages: msgs, Context: ctx}, nil
}

// checkAgentContext makes sure the ids in the context exist, so the model is never told about a
// lesson or question that is not there.
func checkAgentContext(ctx context.Context, lib agentLibrary, c AgentContext) error {
	if c.BankID != "" {
		if _, err := lib.s.reader().GetBank(ctx, c.BankID); err != nil {
			return invalid("context.bank_id does not exist")
		}
	}
	if c.LessonID != "" {
		lessons, err := lib.Lessons(ctx)
		if err != nil {
			return err
		}
		found := false
		for _, l := range lessons {
			if l.ID == c.LessonID {
				found = true
				break
			}
		}
		if !found {
			return invalid("context.lesson_id does not exist")
		}
	}
	if q := c.Question; q != nil {
		qs, err := lib.Questions(ctx)
		if err != nil {
			return err
		}
		found := false
		for _, x := range qs {
			if x.ID == q.ID {
				found = true
				break
			}
		}
		if !found {
			return invalid("context.question.id does not exist")
		}
	}
	return nil
}

func (s *Service) acquireAgentSlot(device string) (release func(), err error) {
	s.agentMu.Lock()
	defer s.agentMu.Unlock()
	if s.agentBusy == nil {
		s.agentBusy = map[string]int{}
	}
	if s.agentBusy[device] >= agentMaxPerDevice {
		return nil, ErrBusy
	}
	s.agentBusy[device]++
	return func() {
		s.agentMu.Lock()
		defer s.agentMu.Unlock()
		if s.agentBusy[device]--; s.agentBusy[device] <= 0 {
			delete(s.agentBusy, device)
		}
	}, nil
}

// agentLibrary gives the assistant read access to the study material.
type agentLibrary struct{ s *Service }

func (l agentLibrary) Banks(ctx context.Context) ([]agent.Bank, error) {
	rows, err := l.s.reader().ListBanks(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]agent.Bank, 0, len(rows))
	for _, b := range rows {
		out = append(out, agent.Bank{ID: b.ID, Title: b.Title})
	}
	return out, nil
}

func (l agentLibrary) Lessons(ctx context.Context) ([]agent.Lesson, error) {
	rows, err := l.s.reader().ListLessons(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]agent.Lesson, 0, len(rows))
	for _, r := range rows {
		out = append(out, agent.Lesson{ID: r.ID, BankID: r.BankID, DocumentID: r.DocumentID,
			DocumentTitle: r.DocumentTitle, HeadingPath: r.HeadingPath, Text: r.Text})
	}
	return out, nil
}

func (l agentLibrary) Questions(ctx context.Context) ([]agent.Question, error) {
	rows, err := l.s.reader().ListAgentQuestions(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]agent.Question, 0, len(rows))
	for _, r := range rows {
		q := agent.Question{ID: r.ID, BankID: r.BankID, LessonID: r.ChunkID.String, Type: r.Type, Stem: r.Stem,
			Explanation: r.Explanation, Difficulty: r.Difficulty, Options: []string{}, Answer: []int{}}
		_ = json.Unmarshal([]byte(r.Options), &q.Options)
		_ = json.Unmarshal([]byte(r.Answer), &q.Answer)
		out = append(out, q)
	}
	return out, nil
}

func (l agentLibrary) Attempts(ctx context.Context) ([]agent.Attempt, error) {
	rows, err := l.s.reader().ListAttemptOutcomes(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]agent.Attempt, 0, len(rows))
	for _, r := range rows {
		out = append(out, agent.Attempt{QuestionID: r.QuestionID, Correct: r.IsCorrect != 0, At: r.AnsweredAt})
	}
	return out, nil
}
