package service

import (
	"context"
	"crypto/subtle"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/chlu-ux/quizmind/server/internal/llm"
	"github.com/chlu-ux/quizmind/server/internal/store"
)

// ErrUnauthorized means the caller did not present a valid app access token.
var ErrUnauthorized = errors.New("unauthorized")

const aiSettingKey = "ai"

// AIConfig is the stored configuration of the AI-explanation feature. The apps call the model
// themselves, so the server hands them the connection details (see AppAIConfig); those come from the
// model bound to the "explain" role (see llmconfig.go). What is kept here is whether the feature is on
// and the token an app must present. Edited in the admin UI.
//
// The connection fields below are how this configuration was stored before models were configured
// separately; SeedLLMConfig moves them over, and they are never written again.
type AIConfig struct {
	Enabled bool `json:"enabled"`
	// AppToken is the (deliberately simple) secret an app must present to fetch
	// the configuration, since it contains the API key. Empty = nobody can.
	AppToken string `json:"app_token"`
	// ReviewAgentQuestions makes the questions the assistant writes wait in the review queue. Off
	// (the default), they are published as soon as they pass the checks, and the learner can take
	// them back.
	ReviewAgentQuestions bool `json:"review_agent_questions,omitempty"`

	BaseURL     string  `json:"base_url,omitempty"`
	APIKey      string  `json:"api_key,omitempty"`
	Model       string  `json:"model,omitempty"`
	MaxTokens   int     `json:"max_tokens,omitempty"`
	Temperature float64 `json:"temperature,omitempty"`
}

func (s *Service) loadAIConfig(ctx context.Context) (AIConfig, error) {
	var cfg AIConfig
	raw, err := s.reader().GetSetting(ctx, aiSettingKey)
	if errors.Is(err, sql.ErrNoRows) {
		return cfg, nil
	}
	if err != nil {
		return cfg, err
	}
	err = json.Unmarshal([]byte(raw), &cfg)
	return cfg, err
}

func keyHint(k string) string {
	r := []rune(k)
	switch {
	case len(r) == 0:
		return ""
	case len(r) <= 8:
		return "已设置"
	}
	return string(r[:3]) + "…" + string(r[len(r)-4:])
}

// explainModel returns the model bound to the explain role and its provider; ok is false when no
// usable model is bound.
func (s *Service) explainModel(ctx context.Context) (m store.LlmModel, p store.LlmProvider, ok bool, err error) {
	q := s.reader()
	roles, err := loadRoles(ctx, q)
	if err != nil {
		return m, p, false, err
	}
	mid, bound := roles[string(llm.RoleExplain)]
	if !bound {
		return m, p, false, nil
	}
	if m, err = q.GetLLMModel(ctx, mid); err != nil {
		return m, p, false, ignoreNoRows(err)
	}
	if p, err = q.GetLLMProvider(ctx, m.ProviderID); err != nil {
		return m, p, false, ignoreNoRows(err)
	}
	return m, p, p.BaseUrl != "" && p.ApiKey != "" && m.Model != "", nil
}

func ignoreNoRows(err error) error {
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	return err
}

// AIConfigView is what the admin UI sees. The model itself is chosen in the model settings.
type AIConfigView struct {
	Enabled  bool   `json:"enabled"`
	AppToken string `json:"app_token"`
	// ReviewAgentQuestions: questions the assistant writes go to the review queue instead of being published.
	ReviewAgentQuestions bool `json:"review_agent_questions"`
	// ModelName is the model bound to the explain role ("provider / model"); empty when none is.
	ModelName string `json:"model_name"`
	// Ready is true when that model is complete enough for an app to use.
	Ready bool `json:"ready"`
}

func (s *Service) AdminAIConfig(ctx context.Context) (AIConfigView, error) {
	c, err := s.loadAIConfig(ctx)
	if err != nil {
		return AIConfigView{}, err
	}
	m, p, ready, err := s.explainModel(ctx)
	if err != nil {
		return AIConfigView{}, err
	}
	v := AIConfigView{Enabled: c.Enabled, AppToken: c.AppToken, ReviewAgentQuestions: c.ReviewAgentQuestions, Ready: ready}
	if m.ID != "" && p.ID != "" {
		v.ModelName = p.Name + " / " + m.Name
	}
	return v, nil
}

// AIConfigUpdate is the admin's edit.
type AIConfigUpdate struct {
	Enabled              bool   `json:"enabled"`
	AppToken             string `json:"app_token"`
	ReviewAgentQuestions bool   `json:"review_agent_questions"`
}

func (s *Service) SaveAIConfig(ctx context.Context, in AIConfigUpdate) (AIConfigView, error) {
	next := AIConfig{Enabled: in.Enabled, AppToken: strings.TrimSpace(in.AppToken), ReviewAgentQuestions: in.ReviewAgentQuestions}
	_, _, ready, err := s.explainModel(ctx)
	if err != nil {
		return AIConfigView{}, err
	}
	switch {
	case next.AppToken != "" && len([]rune(next.AppToken)) < 4:
		return AIConfigView{}, invalid("the access token must have at least 4 characters")
	case next.Enabled && !ready:
		return AIConfigView{}, invalid("choose a model for AI explanations in the model settings first")
	case next.Enabled && next.AppToken == "":
		return AIConfigView{}, invalid("set an access token so the apps can fetch the configuration")
	}
	raw, _ := json.Marshal(next)
	if err := store.New(s.DB.Write).PutSetting(ctx, store.PutSettingParams{Key: aiSettingKey, Value: string(raw)}); err != nil {
		return AIConfigView{}, err
	}
	return s.AdminAIConfig(ctx)
}

func tokenMatches(c AIConfig, token string) bool {
	return c.AppToken != "" && subtle.ConstantTimeCompare([]byte(token), []byte(c.AppToken)) == 1
}

// checkAppToken verifies an app's access token. ErrUnauthorized means it is missing or wrong, or
// that no token has been set (then nobody may present one).
func (s *Service) checkAppToken(ctx context.Context, token string) error {
	c, err := s.loadAIConfig(ctx)
	if err != nil {
		return err
	}
	if !tokenMatches(c, token) {
		return ErrUnauthorized
	}
	return nil
}

// AppAIConfig is what an app receives: the whole configuration, key included.
type AppAIConfig struct {
	BaseURL     string  `json:"base_url"`
	APIKey      string  `json:"api_key"`
	Model       string  `json:"model"`
	MaxTokens   int     `json:"max_tokens"`
	Temperature float64 `json:"temperature"`
}

// AppAIConfig returns the configuration for an app that presents the access
// token. ErrNotFound means the feature is off (the app should drop its copy);
// ErrUnauthorized means the token is missing or wrong.
func (s *Service) AppAIConfig(ctx context.Context, token string) (AppAIConfig, error) {
	c, err := s.loadAIConfig(ctx)
	if err != nil {
		return AppAIConfig{}, err
	}
	m, p, ready, err := s.explainModel(ctx)
	if err != nil {
		return AppAIConfig{}, err
	}
	if !c.Enabled || !ready {
		return AppAIConfig{}, fmt.Errorf("%w: ai config", ErrNotFound)
	}
	if !tokenMatches(c, token) {
		return AppAIConfig{}, ErrUnauthorized
	}
	return AppAIConfig{BaseURL: p.BaseUrl, APIKey: p.ApiKey, Model: m.Model, MaxTokens: int(m.MaxTokens), Temperature: m.Temperature}, nil
}

// ---- explanation sync ----

const maxNoteBytes = 64 << 10

// NoteIn is the AI explanation of one question.
type NoteIn struct {
	QuestionID    string `json:"question_id"`
	Content       string `json:"content"`
	Model         string `json:"model"`
	PromptVersion string `json:"prompt_version"`
	Selected      []int  `json:"selected"`
	UpdatedAt     int64  `json:"updated_at"`
	DeviceID      string `json:"device_id"`
}

type NoteOut struct {
	NoteIn
	SyncSeq int64 `json:"sync_seq"`
}

// UploadNotes merges explanations last-writer-wins on the client's updated_at.
func (s *Service) UploadNotes(ctx context.Context, in []NoteIn) (UploadResult, error) {
	if len(in) > 100 {
		return UploadResult{}, invalid("at most 100 notes per request")
	}
	for i, n := range in {
		switch {
		case n.QuestionID == "" || n.UpdatedAt <= 0:
			return UploadResult{}, invalid("note %d: question_id and updated_at are required", i)
		case strings.TrimSpace(n.Content) == "":
			return UploadResult{}, invalid("note %d: content is empty", i)
		case len(n.Content) > maxNoteBytes:
			return UploadResult{}, invalid("note %d: content is larger than %d bytes", i, maxNoteBytes)
		case len(n.Model) > 200 || len(n.PromptVersion) > 64 || len(n.DeviceID) > 64 || len(n.Selected) > 16:
			return UploadResult{}, invalid("note %d: a field is too long", i)
		}
	}
	var res UploadResult
	err := s.DB.WithTx(ctx, func(tx *sql.Tx) error {
		qs := store.New(tx)
		for _, n := range in {
			seq, err := qs.NextSyncSeq(ctx)
			if err != nil {
				return err
			}
			sel := n.Selected
			if sel == nil {
				sel = []int{}
			}
			selJSON, _ := json.Marshal(sel)
			rows, err := qs.UpsertAINote(ctx, store.UpsertAINoteParams{
				QuestionID: n.QuestionID, Content: n.Content, Model: n.Model, PromptVersion: n.PromptVersion,
				Selected: string(selJSON), UpdatedAt: n.UpdatedAt, DeviceID: n.DeviceID, SyncSeq: seq,
			})
			if err != nil {
				return err
			}
			if rows > 0 {
				res.Accepted++
			} else {
				res.Ignored++
			}
		}
		return nil
	})
	return res, err
}

type SyncNotesPage struct {
	Items   []NoteOut `json:"items"`
	NextSeq int64     `json:"next_seq"`
	HasMore bool      `json:"has_more"`
}

// SyncNotes returns explanations changed after the given server sync_seq.
func (s *Service) SyncNotes(ctx context.Context, since int64, limit int) (SyncNotesPage, error) {
	if limit <= 0 || limit > 100 {
		limit = 100
	}
	rows, err := s.reader().ListAINotesSince(ctx, store.ListAINotesSinceParams{Since: since, PageLimit: int64(limit) + 1})
	if err != nil {
		return SyncNotesPage{}, err
	}
	page := SyncNotesPage{Items: []NoteOut{}, NextSeq: since}
	if len(rows) > limit {
		rows, page.HasMore = rows[:limit], true
	}
	for _, r := range rows {
		sel := []int{}
		_ = json.Unmarshal([]byte(r.Selected), &sel)
		page.NextSeq = r.SyncSeq
		page.Items = append(page.Items, NoteOut{SyncSeq: r.SyncSeq, NoteIn: NoteIn{
			QuestionID: r.QuestionID, Content: r.Content, Model: r.Model, PromptVersion: r.PromptVersion,
			Selected: sel, UpdatedAt: r.UpdatedAt, DeviceID: r.DeviceID,
		}})
	}
	return page, nil
}

// AINoteView is one AI explanation with the question it explains, for the admin UI.
type AINoteView struct {
	QuestionID    string   `json:"question_id"`
	BankID        string   `json:"bank_id"`
	BankTitle     string   `json:"bank_title"`
	Type          string   `json:"type"`
	Stem          string   `json:"stem"`
	Options       []string `json:"options"`
	Answer        []int    `json:"answer"`
	Explanation   string   `json:"explanation"`
	Content       string   `json:"content"`
	Model         string   `json:"model"`
	PromptVersion string   `json:"prompt_version"`
	Selected      []int    `json:"selected"`
	DeviceID      string   `json:"device_id"`
	UpdatedAt     int64    `json:"updated_at"`
}

type AINoteFilter struct {
	BankID, Search string
	Limit, Offset  int
}

type AINotePage struct {
	Items []AINoteView `json:"items"`
	Total int64        `json:"total"`
}

// ListAINotes lists the explanations the devices have uploaded, newest first.
func (s *Service) ListAINotes(ctx context.Context, f AINoteFilter) (AINotePage, error) {
	if f.Limit <= 0 || f.Limit > 200 {
		f.Limit = 20
	}
	if f.Offset < 0 {
		f.Offset = 0
	}
	opt := func(v string) any {
		if v == "" {
			return nil
		}
		return v
	}
	search := strings.TrimSpace(f.Search)
	qs := s.reader()
	rows, err := qs.ListAINotesAdmin(ctx, store.ListAINotesAdminParams{
		BankID: opt(f.BankID), Search: opt(search), PageLimit: int64(f.Limit), PageOffset: int64(f.Offset),
	})
	if err != nil {
		return AINotePage{}, err
	}
	total, err := qs.CountAINotesAdmin(ctx, store.CountAINotesAdminParams{BankID: opt(f.BankID), Search: opt(search)})
	if err != nil {
		return AINotePage{}, err
	}
	page := AINotePage{Items: make([]AINoteView, 0, len(rows)), Total: total}
	for _, r := range rows {
		v := AINoteView{
			QuestionID: r.QuestionID, BankID: r.BankID, BankTitle: r.BankTitle, Type: r.Type, Stem: r.Stem,
			Explanation: r.Explanation, Content: r.Content, Model: r.Model, PromptVersion: r.PromptVersion,
			DeviceID: r.DeviceID, UpdatedAt: r.UpdatedAt,
			Options: []string{}, Answer: []int{}, Selected: []int{},
		}
		_ = json.Unmarshal([]byte(r.Options), &v.Options)
		_ = json.Unmarshal([]byte(r.Answer), &v.Answer)
		_ = json.Unmarshal([]byte(r.Selected), &v.Selected)
		page.Items = append(page.Items, v)
	}
	return page, nil
}
