package service

import (
	"context"
	"crypto/subtle"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"

	"github.com/chlu-ux/quizmind/server/internal/llm/openaicompat"
	"github.com/chlu-ux/quizmind/server/internal/store"
)

// ErrUnauthorized means the caller did not present a valid app access token.
var ErrUnauthorized = errors.New("unauthorized")

const aiSettingKey = "ai"

// AIConfig is the stored configuration of the AI-explanation feature. The apps
// call the model themselves, so it is handed to them (see AppAIConfig); the
// server only keeps it. Edited in the admin UI.
type AIConfig struct {
	Enabled     bool    `json:"enabled"`
	BaseURL     string  `json:"base_url"` // OpenAI-compatible, including the version segment, e.g. https://api.openai.com/v1
	APIKey      string  `json:"api_key"`
	Model       string  `json:"model"`
	MaxTokens   int     `json:"max_tokens"`
	Temperature float64 `json:"temperature"`
	// AppToken is the (deliberately simple) secret an app must present to fetch
	// the configuration, since it contains the API key. Empty = nobody can.
	AppToken string `json:"app_token"`
}

func defaultAIConfig() AIConfig { return AIConfig{MaxTokens: 1500, Temperature: 0.3} }

func (s *Service) loadAIConfig(ctx context.Context) (AIConfig, error) {
	cfg := defaultAIConfig()
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

// AIConfigView is what the admin UI sees: everything except the API key itself.
type AIConfigView struct {
	Enabled     bool    `json:"enabled"`
	BaseURL     string  `json:"base_url"`
	Model       string  `json:"model"`
	MaxTokens   int     `json:"max_tokens"`
	Temperature float64 `json:"temperature"`
	AppToken    string  `json:"app_token"`
	APIKeySet   bool    `json:"api_key_set"`
	APIKeyHint  string  `json:"api_key_hint"` // e.g. "sk-…a1b2"
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

func (s *Service) AdminAIConfig(ctx context.Context) (AIConfigView, error) {
	c, err := s.loadAIConfig(ctx)
	if err != nil {
		return AIConfigView{}, err
	}
	return AIConfigView{
		Enabled: c.Enabled, BaseURL: c.BaseURL, Model: c.Model, MaxTokens: c.MaxTokens,
		Temperature: c.Temperature, AppToken: c.AppToken, APIKeySet: c.APIKey != "", APIKeyHint: keyHint(c.APIKey),
	}, nil
}

// AIConfigUpdate is the admin's edit. APIKey nil or empty keeps the stored key.
type AIConfigUpdate struct {
	Enabled     bool    `json:"enabled"`
	BaseURL     string  `json:"base_url"`
	APIKey      string  `json:"api_key"`
	Model       string  `json:"model"`
	MaxTokens   int     `json:"max_tokens"`
	Temperature float64 `json:"temperature"`
	AppToken    string  `json:"app_token"`
}

func (s *Service) SaveAIConfig(ctx context.Context, in AIConfigUpdate) (AIConfigView, error) {
	cur, err := s.loadAIConfig(ctx)
	if err != nil {
		return AIConfigView{}, err
	}
	next := AIConfig{
		Enabled: in.Enabled, BaseURL: strings.TrimRight(strings.TrimSpace(in.BaseURL), "/"),
		APIKey: cur.APIKey, Model: strings.TrimSpace(in.Model), MaxTokens: in.MaxTokens,
		Temperature: in.Temperature, AppToken: strings.TrimSpace(in.AppToken),
	}
	if k := strings.TrimSpace(in.APIKey); k != "" {
		next.APIKey = k
	}
	if next.MaxTokens == 0 {
		next.MaxTokens = defaultAIConfig().MaxTokens
	}
	if next.BaseURL != "" {
		if u, err := url.Parse(next.BaseURL); err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
			return AIConfigView{}, invalid("base_url must be an http(s) URL such as https://api.openai.com/v1")
		}
	}
	switch {
	case next.MaxTokens < 16 || next.MaxTokens > 32000:
		return AIConfigView{}, invalid("max_tokens must be between 16 and 32000")
	case next.Temperature < 0 || next.Temperature > 2:
		return AIConfigView{}, invalid("temperature must be between 0 and 2")
	case next.AppToken != "" && len([]rune(next.AppToken)) < 4:
		return AIConfigView{}, invalid("the access token must have at least 4 characters")
	case next.Enabled && (next.BaseURL == "" || next.APIKey == "" || next.Model == ""):
		return AIConfigView{}, invalid("base_url, api_key and model are required to enable AI explanations")
	case next.Enabled && next.AppToken == "":
		return AIConfigView{}, invalid("set an access token so the apps can fetch the configuration")
	}
	raw, _ := json.Marshal(next)
	if err := store.New(s.DB.Write).PutSetting(ctx, store.PutSettingParams{Key: aiSettingKey, Value: string(raw)}); err != nil {
		return AIConfigView{}, err
	}
	return s.AdminAIConfig(ctx)
}

type AITestResult struct {
	OK      bool   `json:"ok"`
	Reply   string `json:"reply,omitempty"`
	Error   string `json:"error,omitempty"`
	Latency int64  `json:"latency_ms"`
}

// TestAIConfig sends a tiny request with the saved configuration. A failing
// endpoint is a result, not an error: the admin UI shows what went wrong.
func (s *Service) TestAIConfig(ctx context.Context) (AITestResult, error) {
	c, err := s.loadAIConfig(ctx)
	if err != nil {
		return AITestResult{}, err
	}
	if c.BaseURL == "" || c.APIKey == "" || c.Model == "" {
		return AITestResult{Error: "请先保存 Base URL、API Key 和模型"}, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	start := time.Now()
	reply, err := openaicompat.Chat(ctx, nil, c.BaseURL, c.APIKey, c.Model, "Reply with the single word: pong", 32)
	res := AITestResult{Latency: time.Since(start).Milliseconds()}
	if err != nil {
		res.Error = strings.ReplaceAll(err.Error(), c.APIKey, "***")
		return res, nil
	}
	res.OK, res.Reply = true, strings.TrimSpace(reply)
	return res, nil
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
	if !c.Enabled || c.BaseURL == "" || c.APIKey == "" || c.Model == "" {
		return AppAIConfig{}, fmt.Errorf("%w: ai config", ErrNotFound)
	}
	if c.AppToken == "" || subtle.ConstantTimeCompare([]byte(token), []byte(c.AppToken)) != 1 {
		return AppAIConfig{}, ErrUnauthorized
	}
	return AppAIConfig{BaseURL: c.BaseURL, APIKey: c.APIKey, Model: c.Model, MaxTokens: c.MaxTokens, Temperature: c.Temperature}, nil
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
