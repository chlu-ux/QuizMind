package service

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/chlu-ux/quizmind/server/internal/agent"
	"github.com/chlu-ux/quizmind/server/internal/llm"
)

// maxAgentUpload is how many questions one upload request may carry.
const maxAgentUpload = 20

// LocalAgentModel is the connection an app uses to run the assistant itself. The key is handed over
// like the one of the explanation model: the apps are the server's own, and the access token guards it.
type LocalAgentModel struct {
	// BaseURL is the provider's Anthropic-protocol address; the app posts to {BaseURL}/v1/messages.
	BaseURL   string `json:"base_url"`
	APIKey    string `json:"api_key"`
	Model     string `json:"model"`
	MaxTokens int    `json:"max_tokens"`
	Effort    string `json:"effort"`
	Vision    bool   `json:"vision"`
}

// LocalAgentSpec is what an app needs to run the assistant without the server: how to reach the
// model, the instructions and tools, and the rules a question must meet before it is uploaded.
type LocalAgentSpec struct {
	agent.Spec
	Model LocalAgentModel `json:"model"`
	// DedupeThreshold is the trigram similarity above which a new question counts as a duplicate.
	DedupeThreshold float64 `json:"dedupe_threshold"`
}

// LocalAgentSpec returns the spec for an app that presents the access token. ErrNotFound means no
// model is bound to the assistant.
func (s *Service) LocalAgentSpec(ctx context.Context, token string) (LocalAgentSpec, error) {
	if err := s.checkAppToken(ctx, token); err != nil {
		return LocalAgentSpec{}, err
	}
	q := s.reader()
	roles, err := loadRoles(ctx, q)
	if err != nil {
		return LocalAgentSpec{}, err
	}
	notBound := fmt.Errorf("%w: assistant is not configured", ErrNotFound)
	mid, ok := roles[string(llm.RoleAgent)]
	if !ok {
		return LocalAgentSpec{}, notBound
	}
	m, err := q.GetLLMModel(ctx, mid)
	if err != nil {
		return LocalAgentSpec{}, notFoundOr(err, notBound)
	}
	p, err := q.GetLLMProvider(ctx, m.ProviderID)
	if err != nil {
		return LocalAgentSpec{}, notFoundOr(err, notBound)
	}
	if p.BaseUrl == "" || p.ApiKey == "" || m.Model == "" || llm.Protocol(p.Protocol) != llm.ProtocolAnthropic {
		return LocalAgentSpec{}, notBound
	}
	maxTokens := int(m.MaxTokens)
	if maxTokens <= 0 {
		maxTokens = 16000
	}
	return LocalAgentSpec{
		Spec: agent.BuildSpec(),
		Model: LocalAgentModel{BaseURL: p.BaseUrl, APIKey: p.ApiKey, Model: m.Model, MaxTokens: maxTokens,
			Effort: m.Effort, Vision: m.Vision != 0},
		DedupeThreshold: s.Cfg.Pipeline.DedupeThreshold,
	}, nil
}

func notFoundOr(err, notFound error) error {
	if errors.Is(err, sql.ErrNoRows) {
		return notFound
	}
	return err
}

// AgentQuestionIn is a question the assistant wrote on a device that could not reach the server.
// The device chose the id; it is the question's id from now on, so the apps' accept / discard calls
// and the next sync refer to the same row.
type AgentQuestionIn struct {
	ID             string   `json:"id"`
	LessonID       string   `json:"lesson_id"`
	ConversationID string   `json:"conversation_id"`
	DeviceID       string   `json:"device_id"`
	Model          string   `json:"model"`
	Type           string   `json:"type"`
	Stem           string   `json:"stem"`
	Options        []string `json:"options"`
	AnswerIndex    int      `json:"answer_index"`
	Explanation    string   `json:"explanation"`
	Difficulty     int      `json:"difficulty"`
	Tags           []string `json:"tags"`
	SourceQuote    string   `json:"source_quote"`
}

// AgentQuestionResult says what became of one uploaded question. Status is the question's status on
// the server (published, needs_review, or rejected when the learner took it back meanwhile); Error
// says, in words for the learner, why a question was refused.
type AgentQuestionResult struct {
	ID       string `json:"id"`
	OK       bool   `json:"ok"`
	Status   string `json:"status,omitempty"`
	Verified bool   `json:"verified"`
	Error    string `json:"error,omitempty"`
}

// UploadAgentQuestions takes the questions an app wrote offline. The server does not trust them: each
// goes through the same checks as a question the server's own assistant writes (rules, duplicates of
// the whole bank, and the independent reviewer when one is bound) and is stored adopted. Sending one
// twice is harmless: the second time reports the first one's outcome.
func (s *Service) UploadAgentQuestions(ctx context.Context, token string, in []AgentQuestionIn) ([]AgentQuestionResult, error) {
	if err := s.checkAppToken(ctx, token); err != nil {
		return nil, err
	}
	if len(in) == 0 || len(in) > maxAgentUpload {
		return nil, invalid("send 1 to %d questions per request", maxAgentUpload)
	}
	for i, x := range in {
		switch {
		case x.ID == "" || len(x.ID) > agentIDMax:
			return nil, invalid("question %d: id is required and at most %d characters", i, agentIDMax)
		case x.LessonID == "" || len(x.LessonID) > agentIDMax:
			return nil, invalid("question %d: lesson_id is required", i)
		case x.ConversationID == "" || len(x.ConversationID) > agentIDMax || len(x.DeviceID) > agentIDMax:
			return nil, invalid("question %d: conversation_id is required; ids are at most %d characters", i, agentIDMax)
		case len(x.Model) > 200 || len(x.Options) > 8 || len(x.Tags) > 20:
			return nil, invalid("question %d: a field is too long", i)
		}
	}
	out := make([]AgentQuestionResult, len(in))
	for i, x := range in {
		if row, err := s.reader().GetAgentDraft(ctx, x.ID); err == nil {
			out[i] = AgentQuestionResult{ID: x.ID, OK: true, Status: row.Status, Verified: row.Verified != 0}
			continue
		} else if !errors.Is(err, sql.ErrNoRows) {
			return nil, err
		}
		model := x.Model
		if model == "" {
			model = "device"
		}
		res, err := agentDrafter{s: s, model: model}.Propose(ctx,
			agent.DraftScope{ConversationID: x.ConversationID, DeviceID: x.DeviceID}, x.LessonID,
			[]agent.ProposedQuestion{{Type: x.Type, Stem: x.Stem, Options: x.Options, AnswerIndex: x.AnswerIndex,
				Explanation: x.Explanation, Difficulty: x.Difficulty, Tags: x.Tags, SourceQuote: x.SourceQuote, ClientID: x.ID}})
		if err != nil {
			return nil, err
		}
		r := res[0]
		if !r.OK {
			out[i] = AgentQuestionResult{ID: x.ID, Error: r.Error}
			continue
		}
		status, err := s.agentQuestionStatus(ctx, x.ID)
		if err != nil {
			return nil, err
		}
		out[i] = AgentQuestionResult{ID: x.ID, OK: true, Status: status, Verified: r.Draft != nil && r.Draft.Verified}
	}
	return out, nil
}

func (s *Service) agentQuestionStatus(ctx context.Context, id string) (string, error) {
	row, err := s.reader().GetAgentDraft(ctx, id)
	if err != nil {
		return "", err
	}
	return row.Status, nil
}
