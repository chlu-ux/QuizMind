package service

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/chlu-ux/quizmind/server/internal/llm"
	"github.com/chlu-ux/quizmind/server/internal/llm/anthropic"
	"github.com/chlu-ux/quizmind/server/internal/llm/openaicompat"
	"github.com/chlu-ux/quizmind/server/internal/store"
)

// Model providers, models and the roles they play are edited in the admin UI and kept in the
// database: providers and models in their own tables, the role bindings and call limits as JSON in
// app_setting.
const (
	llmRolesKey  = "llm_roles"
	llmLimitsKey = "llm_limits"
	// llmSeededKey marks that the first-start import of the old config.yaml / environment settings has
	// run, so deleting everything later does not bring the old settings back.
	llmSeededKey = "llm_seeded"
)

// llmRoleNames are the roles that can be bound to a model.
var llmRoleNames = []llm.Role{llm.RoleGenerator, llm.RoleValidator, llm.RoleAgent, llm.RoleExplain}

// roleProtocol is the protocol a role insists on; roles missing here accept either.
var roleProtocol = map[llm.Role]llm.Protocol{
	// The agent drives tool calls and streams, which is built on the Anthropic protocol.
	llm.RoleAgent: llm.ProtocolAnthropic,
	// The apps call the explanation model themselves with OpenAI-style chat completions.
	llm.RoleExplain: llm.ProtocolOpenAI,
}

var efforts = map[string]bool{"": true, "low": true, "medium": true, "high": true, "xhigh": true, "max": true}

// ProviderView is a provider as the admin UI sees it: everything except the key itself.
type ProviderView struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Protocol   string `json:"protocol"`
	BaseURL    string `json:"base_url"`
	APIKeySet  bool   `json:"api_key_set"`
	APIKeyHint string `json:"api_key_hint"`
}

// ProviderInput is an admin's edit. APIKey empty keeps the stored key (required when creating).
type ProviderInput struct {
	Name     string `json:"name"`
	Protocol string `json:"protocol"`
	BaseURL  string `json:"base_url"`
	APIKey   string `json:"api_key"`
}

type ModelView struct {
	ID          string  `json:"id"`
	ProviderID  string  `json:"provider_id"`
	Name        string  `json:"name"`
	Model       string  `json:"model"`
	MaxTokens   int     `json:"max_tokens"`
	Temperature float64 `json:"temperature"`
	Effort      string  `json:"effort"`
	// Vision says the model can look at pictures (only the assistant's model uses it).
	Vision bool `json:"vision"`
}

type ModelInput struct {
	ProviderID  string  `json:"provider_id"`
	Name        string  `json:"name"`
	Model       string  `json:"model"`
	MaxTokens   int     `json:"max_tokens"`
	Temperature float64 `json:"temperature"`
	Effort      string  `json:"effort"`
	Vision      bool    `json:"vision"`
}

// LLMLimits apply to every server-side model call together.
type LLMLimits struct {
	MaxConcurrency   int     `json:"max_concurrency"`
	RPS              float64 `json:"rps"`
	DailyTokenBudget int64   `json:"daily_token_budget"` // 0 = unlimited
}

// LLMConfigView is the whole model configuration. Roles maps a role name to a model id; a role
// that is not bound is absent.
type LLMConfigView struct {
	Providers []ProviderView    `json:"providers"`
	Models    []ModelView       `json:"models"`
	Roles     map[string]string `json:"roles"`
	Limits    LLMLimits         `json:"limits"`
}

func providerView(p store.LlmProvider) ProviderView {
	return ProviderView{ID: p.ID, Name: p.Name, Protocol: p.Protocol, BaseURL: p.BaseUrl,
		APIKeySet: p.ApiKey != "", APIKeyHint: keyHint(p.ApiKey)}
}

func modelView(m store.LlmModel) ModelView {
	return ModelView{ID: m.ID, ProviderID: m.ProviderID, Name: m.Name, Model: m.Model,
		MaxTokens: int(m.MaxTokens), Temperature: m.Temperature, Effort: m.Effort, Vision: m.Vision != 0}
}

func defaultLLMLimits() LLMLimits {
	return LLMLimits{MaxConcurrency: 2, RPS: 2, DailyTokenBudget: 2_000_000}
}

func (l LLMLimits) toGuard() llm.Limits {
	return llm.Limits{MaxConcurrency: l.MaxConcurrency, RPS: l.RPS, DailyTokenBudget: l.DailyTokenBudget}
}

// ---- stored settings ----

func loadRoles(ctx context.Context, q *store.Queries) (map[string]string, error) {
	roles := map[string]string{}
	raw, err := q.GetSetting(ctx, llmRolesKey)
	if errors.Is(err, sql.ErrNoRows) {
		return roles, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal([]byte(raw), &roles); err != nil {
		return nil, fmt.Errorf("stored %s: %w", llmRolesKey, err)
	}
	return roles, nil
}

func saveRoles(ctx context.Context, q *store.Queries, roles map[string]string) error {
	raw, _ := json.Marshal(roles)
	return q.PutSetting(ctx, store.PutSettingParams{Key: llmRolesKey, Value: string(raw)})
}

func loadLimits(ctx context.Context, q *store.Queries) (LLMLimits, error) {
	l := defaultLLMLimits()
	raw, err := q.GetSetting(ctx, llmLimitsKey)
	if errors.Is(err, sql.ErrNoRows) {
		return l, nil
	}
	if err != nil {
		return l, err
	}
	if err := json.Unmarshal([]byte(raw), &l); err != nil {
		return l, fmt.Errorf("stored %s: %w", llmLimitsKey, err)
	}
	return l, nil
}

// ---- read ----

func (s *Service) LLMConfig(ctx context.Context) (LLMConfigView, error) {
	return s.llmConfig(ctx, s.reader())
}

func (s *Service) llmConfig(ctx context.Context, q *store.Queries) (LLMConfigView, error) {
	providers, err := q.ListLLMProviders(ctx)
	if err != nil {
		return LLMConfigView{}, err
	}
	models, err := q.ListLLMModels(ctx)
	if err != nil {
		return LLMConfigView{}, err
	}
	roles, err := loadRoles(ctx, q)
	if err != nil {
		return LLMConfigView{}, err
	}
	limits, err := loadLimits(ctx, q)
	if err != nil {
		return LLMConfigView{}, err
	}
	v := LLMConfigView{Providers: []ProviderView{}, Models: []ModelView{}, Roles: roles, Limits: limits}
	for _, p := range providers {
		v.Providers = append(v.Providers, providerView(p))
	}
	for _, m := range models {
		v.Models = append(v.Models, modelView(m))
	}
	return v, nil
}

// ---- providers ----

func validateProvider(in *ProviderInput) error {
	in.Name = strings.TrimSpace(in.Name)
	in.BaseURL = strings.TrimRight(strings.TrimSpace(in.BaseURL), "/")
	in.APIKey = strings.TrimSpace(in.APIKey)
	switch {
	case in.Name == "" || len([]rune(in.Name)) > 60:
		return invalid("name is required and at most 60 characters")
	case in.Protocol != string(llm.ProtocolAnthropic) && in.Protocol != string(llm.ProtocolOpenAI):
		return invalid("protocol must be anthropic or openai")
	case in.Protocol == string(llm.ProtocolOpenAI) && in.BaseURL == "":
		return invalid("base_url is required for an OpenAI-compatible provider, e.g. https://api.openai.com/v1")
	}
	if in.BaseURL != "" {
		if u, err := url.Parse(in.BaseURL); err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
			return invalid("base_url must be an http(s) URL")
		}
	}
	return nil
}

func (s *Service) CreateProvider(ctx context.Context, in ProviderInput) (ProviderView, error) {
	if err := validateProvider(&in); err != nil {
		return ProviderView{}, err
	}
	if in.APIKey == "" {
		return ProviderView{}, invalid("api_key is required")
	}
	now := nowMs()
	p := store.LlmProvider{ID: newID(), Name: in.Name, Protocol: in.Protocol, BaseUrl: in.BaseURL,
		ApiKey: in.APIKey, CreatedAt: now, UpdatedAt: now}
	err := store.New(s.DB.Write).InsertLLMProvider(ctx, store.InsertLLMProviderParams{ID: p.ID, Name: p.Name,
		Protocol: p.Protocol, BaseUrl: p.BaseUrl, ApiKey: p.ApiKey, CreatedAt: now, UpdatedAt: now})
	if err != nil {
		return ProviderView{}, err
	}
	s.reloadAfterEdit(ctx)
	return providerView(p), nil
}

func (s *Service) UpdateProvider(ctx context.Context, id string, in ProviderInput) (ProviderView, error) {
	if err := validateProvider(&in); err != nil {
		return ProviderView{}, err
	}
	var out ProviderView
	err := s.DB.WithTx(ctx, func(tx *sql.Tx) error {
		q := store.New(tx)
		cur, err := q.GetLLMProvider(ctx, id)
		if err != nil {
			return notFound(err, "provider")
		}
		key := cur.ApiKey
		if in.APIKey != "" {
			key = in.APIKey
		}
		if _, err := q.UpdateLLMProvider(ctx, store.UpdateLLMProviderParams{Name: in.Name, Protocol: in.Protocol,
			BaseUrl: in.BaseURL, ApiKey: key, UpdatedAt: nowMs(), ID: id}); err != nil {
			return err
		}
		// A changed protocol can break a role that insists on one.
		if err := checkBoundRoles(ctx, q); err != nil {
			return err
		}
		next, err := q.GetLLMProvider(ctx, id)
		out = providerView(next)
		return err
	})
	if err != nil {
		return ProviderView{}, err
	}
	s.reloadAfterEdit(ctx)
	return out, nil
}

func (s *Service) DeleteProvider(ctx context.Context, id string) error {
	err := s.DB.WithTx(ctx, func(tx *sql.Tx) error {
		q := store.New(tx)
		if _, err := q.GetLLMProvider(ctx, id); err != nil {
			return notFound(err, "provider")
		}
		models, err := q.ListLLMModelsByProvider(ctx, id)
		if err != nil {
			return err
		}
		if len(models) > 0 {
			return invalid("delete this provider's %d model(s) first", len(models))
		}
		return q.DeleteLLMProvider(ctx, id)
	})
	if err != nil {
		return err
	}
	s.reloadAfterEdit(ctx)
	return nil
}

// ---- models ----

func validateModel(in *ModelInput) error {
	in.Name = strings.TrimSpace(in.Name)
	in.Model = strings.TrimSpace(in.Model)
	if in.MaxTokens == 0 {
		in.MaxTokens = 8000
	}
	switch {
	case in.Model == "" || len(in.Model) > 200:
		return invalid("model is required (the model id sent to the provider)")
	case len([]rune(in.Name)) > 60:
		return invalid("name is at most 60 characters")
	case in.MaxTokens < 16 || in.MaxTokens > 64000:
		return invalid("max_tokens must be between 16 and 64000")
	case in.Temperature < 0 || in.Temperature > 2:
		return invalid("temperature must be between 0 and 2")
	case !efforts[in.Effort]:
		return invalid("effort must be empty, low, medium, high, xhigh or max")
	}
	if in.Name == "" {
		in.Name = in.Model
	}
	return nil
}

func (s *Service) CreateModel(ctx context.Context, in ModelInput) (ModelView, error) {
	if err := validateModel(&in); err != nil {
		return ModelView{}, err
	}
	if _, err := s.reader().GetLLMProvider(ctx, in.ProviderID); err != nil {
		return ModelView{}, invalid("unknown provider")
	}
	now := nowMs()
	m := store.LlmModel{ID: newID(), ProviderID: in.ProviderID, Name: in.Name, Model: in.Model,
		MaxTokens: int64(in.MaxTokens), Temperature: in.Temperature, Effort: in.Effort, Vision: boolInt(in.Vision), CreatedAt: now, UpdatedAt: now}
	err := store.New(s.DB.Write).InsertLLMModel(ctx, store.InsertLLMModelParams{ID: m.ID, ProviderID: m.ProviderID,
		Name: m.Name, Model: m.Model, MaxTokens: m.MaxTokens, Temperature: m.Temperature, Effort: m.Effort, Vision: m.Vision,
		CreatedAt: now, UpdatedAt: now})
	if err != nil {
		return ModelView{}, err
	}
	return modelView(m), nil // an unbound model changes nothing that is running
}

func (s *Service) UpdateModel(ctx context.Context, id string, in ModelInput) (ModelView, error) {
	if err := validateModel(&in); err != nil {
		return ModelView{}, err
	}
	var out ModelView
	err := s.DB.WithTx(ctx, func(tx *sql.Tx) error {
		q := store.New(tx)
		if _, err := q.GetLLMModel(ctx, id); err != nil {
			return notFound(err, "model")
		}
		if _, err := q.GetLLMProvider(ctx, in.ProviderID); err != nil {
			return invalid("unknown provider")
		}
		if _, err := q.UpdateLLMModel(ctx, store.UpdateLLMModelParams{ProviderID: in.ProviderID, Name: in.Name,
			Model: in.Model, MaxTokens: int64(in.MaxTokens), Temperature: in.Temperature, Effort: in.Effort, Vision: boolInt(in.Vision),
			UpdatedAt: nowMs(), ID: id}); err != nil {
			return err
		}
		if err := checkBoundRoles(ctx, q); err != nil {
			return err
		}
		next, err := q.GetLLMModel(ctx, id)
		out = modelView(next)
		return err
	})
	if err != nil {
		return ModelView{}, err
	}
	s.reloadAfterEdit(ctx)
	return out, nil
}

func (s *Service) DeleteModel(ctx context.Context, id string) error {
	return s.DB.WithTx(ctx, func(tx *sql.Tx) error {
		q := store.New(tx)
		if _, err := q.GetLLMModel(ctx, id); err != nil {
			return notFound(err, "model")
		}
		roles, err := loadRoles(ctx, q)
		if err != nil {
			return err
		}
		for role, mid := range roles {
			if mid == id {
				return invalid("the model is used by the %q role; choose another model for it first", role)
			}
		}
		return q.DeleteLLMModel(ctx, id)
	})
}

// ---- roles and limits ----

// checkBoundRoles verifies the stored role bindings still make sense: each bound model exists, and
// its provider speaks the protocol the role needs.
func checkBoundRoles(ctx context.Context, q *store.Queries) error {
	roles, err := loadRoles(ctx, q)
	if err != nil {
		return err
	}
	return checkRoles(ctx, q, roles)
}

func checkRoles(ctx context.Context, q *store.Queries, roles map[string]string) error {
	known := map[string]bool{}
	for _, r := range llmRoleNames {
		known[string(r)] = true
	}
	for role, mid := range roles {
		if !known[role] {
			return invalid("unknown role %q", role)
		}
		m, err := q.GetLLMModel(ctx, mid)
		if err != nil {
			return invalid("role %q: unknown model", role)
		}
		p, err := q.GetLLMProvider(ctx, m.ProviderID)
		if err != nil {
			return err
		}
		if want, ok := roleProtocol[llm.Role(role)]; ok && p.Protocol != string(want) {
			return invalid("the %q role needs a model from an %s-protocol provider (%q is %s)", role, want, m.Name, p.Protocol)
		}
	}
	return nil
}

// SaveRoles replaces the role bindings. An empty model id (or a missing role) leaves the role unbound.
func (s *Service) SaveRoles(ctx context.Context, in map[string]string) (LLMConfigView, error) {
	roles := map[string]string{}
	for role, mid := range in {
		if mid = strings.TrimSpace(mid); mid != "" {
			roles[role] = mid
		}
	}
	err := s.DB.WithTx(ctx, func(tx *sql.Tx) error {
		q := store.New(tx)
		if err := checkRoles(ctx, q, roles); err != nil {
			return err
		}
		return saveRoles(ctx, q, roles)
	})
	if err != nil {
		return LLMConfigView{}, err
	}
	s.reloadAfterEdit(ctx)
	return s.LLMConfig(ctx)
}

func (s *Service) SaveLimits(ctx context.Context, in LLMLimits) (LLMConfigView, error) {
	switch {
	case in.MaxConcurrency < 1 || in.MaxConcurrency > 16:
		return LLMConfigView{}, invalid("max_concurrency must be between 1 and 16")
	case in.RPS < 0 || in.RPS > 100:
		return LLMConfigView{}, invalid("rps must be between 0 (unlimited) and 100")
	case in.DailyTokenBudget < 0:
		return LLMConfigView{}, invalid("daily_token_budget cannot be negative")
	}
	raw, _ := json.Marshal(in)
	if err := store.New(s.DB.Write).PutSetting(ctx, store.PutSettingParams{Key: llmLimitsKey, Value: string(raw)}); err != nil {
		return LLMConfigView{}, err
	}
	s.reloadAfterEdit(ctx)
	return s.LLMConfig(ctx)
}

// ---- applying the configuration ----

// reloadAfterEdit applies a saved change to the running clients. The change is already stored, so a
// failure here only means some role is not usable yet; it is logged rather than failing the edit.
func (s *Service) reloadAfterEdit(ctx context.Context) {
	if err := s.ReloadLLM(ctx); err != nil {
		s.Log.Warn("reload llm configuration", "err", err)
	}
}

// ReloadLLM rebuilds the model clients from the stored configuration and swaps them in. A role whose
// model cannot be built (no key, bad address) is left unconfigured with a warning, so the rest of the
// server keeps working and jobs for that role fail with a clear "no client configured" error.
func (s *Service) ReloadLLM(ctx context.Context) error {
	q := s.reader()
	view, err := s.llmConfig(ctx, q)
	if err != nil {
		return err
	}
	s.Guard.SetLimits(view.Limits.toGuard())

	providers := map[string]store.LlmProvider{}
	list, err := q.ListLLMProviders(ctx)
	if err != nil {
		return err
	}
	for _, p := range list {
		providers[p.ID] = p
	}
	clients := map[llm.Role]llm.Client{}
	conversers := map[llm.Role]llm.Converser{}
	for _, role := range llmRoleNames {
		mid, ok := view.Roles[string(role)]
		if !ok || role == llm.RoleExplain { // the apps call the explanation model themselves
			continue
		}
		m, err := q.GetLLMModel(ctx, mid)
		if err != nil {
			s.Log.Warn("llm role disabled: model not found", "role", role, "model", mid)
			continue
		}
		c, err := buildClient(providers[m.ProviderID], m)
		if err != nil {
			s.Log.Warn("llm role disabled", "role", role, "model", m.Name, "err", err)
			continue
		}
		clients[role] = s.Guard.Wrap(role, c)
		if conv, ok := c.(llm.Converser); ok && role == llm.RoleAgent {
			conversers[role] = s.Guard.WrapConverser(role, conv)
		}
		s.Log.Info("llm role ready", "role", role, "protocol", providers[m.ProviderID].Protocol, "model", m.Model)
	}
	s.LLM.ReplaceAll(clients, conversers)
	return nil
}

func buildClient(p store.LlmProvider, m store.LlmModel) (llm.Client, error) {
	if p.ApiKey == "" {
		return nil, fmt.Errorf("provider %q has no API key", p.Name)
	}
	switch llm.Protocol(p.Protocol) {
	case llm.ProtocolAnthropic:
		return anthropic.New(anthropic.Options{APIKey: p.ApiKey, BaseURL: p.BaseUrl, Model: m.Model,
			Effort: m.Effort, MaxTokens: int(m.MaxTokens)})
	case llm.ProtocolOpenAI:
		return openaicompat.New(openaicompat.Options{APIKey: p.ApiKey, BaseURL: p.BaseUrl, Model: m.Model,
			MaxTokens: int(m.MaxTokens), Temperature: m.Temperature})
	}
	return nil, fmt.Errorf("provider %q: unknown protocol %q", p.Name, p.Protocol)
}

// ---- testing a model ----

type ModelTestResult struct {
	OK      bool   `json:"ok"`
	Reply   string `json:"reply,omitempty"`
	Error   string `json:"error,omitempty"`
	Latency int64  `json:"latency_ms"`
	// Checks is the compatibility report for a model bound to the assistant role: streaming, tool
	// calls and multi-turn tool use. OK is false when a check failed, even though the model answered.
	Checks []llm.Check `json:"checks,omitempty"`
}

// TestModel sends a tiny request to a saved model. A failing endpoint is a result, not an error:
// the admin UI shows what went wrong. The call does not count against the limits or the budget.
func (s *Service) TestModel(ctx context.Context, id string) (ModelTestResult, error) {
	q := s.reader()
	m, err := q.GetLLMModel(ctx, id)
	if err != nil {
		return ModelTestResult{}, notFound(err, "model")
	}
	p, err := q.GetLLMProvider(ctx, m.ProviderID)
	if err != nil {
		return ModelTestResult{}, err
	}
	c, err := buildClient(p, m)
	if err != nil {
		return ModelTestResult{Error: err.Error()}, nil
	}
	pinger, ok := c.(llm.Pinger)
	if !ok {
		return ModelTestResult{Error: "this provider cannot be tested"}, nil
	}
	start := time.Now()
	reply, err := pinger.Ping(ctx)
	res := ModelTestResult{Latency: time.Since(start).Milliseconds()}
	if err != nil {
		res.Error = strings.ReplaceAll(err.Error(), p.ApiKey, "***")
		return res, nil
	}
	res.OK, res.Reply = true, strings.TrimSpace(reply)

	// A model that drives the assistant must also stream and use tools, which gateways often get wrong.
	if roles, err := loadRoles(ctx, q); err == nil && roles[string(llm.RoleAgent)] == m.ID {
		if prober, ok := c.(llm.Prober); ok {
			res.Checks = prober.Probe(ctx)
			for _, ch := range res.Checks {
				// A noisy reply is filtered out, so it is a warning and does not fail the model.
				if !ch.OK && ch.Name != "正文干净" {
					res.OK = false
					res.Error = "该模型不能用作助手：" + ch.Name + "未通过"
					break
				}
			}
			for i := range res.Checks {
				res.Checks[i].Detail = strings.ReplaceAll(res.Checks[i].Detail, p.ApiKey, "***")
			}
		}
	}
	return res, nil
}

// ---- first-start import ----

// SeedLLMConfig imports the settings that used to live elsewhere, once: the providers and roles of
// config.yaml (their keys read from the environment variables it names) and the AI-explanation
// endpoint saved in the admin UI. It does nothing when the database already holds a configuration or
// the import has run before.
func (s *Service) SeedLLMConfig(ctx context.Context) error {
	q := s.reader()
	if _, err := q.GetSetting(ctx, llmSeededKey); err == nil {
		return nil
	} else if !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	legacyAI, err := s.loadAIConfig(ctx)
	if err != nil {
		return err
	}
	return s.DB.WithTx(ctx, func(tx *sql.Tx) error {
		q := store.New(tx)
		existing, err := q.ListLLMProviders(ctx)
		if err != nil {
			return err
		}
		put := func(key, value string) error {
			return q.PutSetting(ctx, store.PutSettingParams{Key: key, Value: value})
		}
		if len(existing) > 0 {
			return put(llmSeededKey, "1")
		}
		roles := map[string]string{}
		now := nowMs()
		providerIDs := map[string]string{} // legacy provider name -> new id

		legacy := s.Cfg.LLM
		names := make([]string, 0, len(legacy.Roles))
		for name := range legacy.Roles {
			names = append(names, name)
		}
		sort.Strings(names)
		for _, name := range names {
			role := legacy.Roles[name]
			prov, ok := legacy.Providers[role.Provider]
			if !ok || prov.Type != string(llm.ProtocolAnthropic) || !isRole(name) {
				continue
			}
			key := os.Getenv(prov.APIKeyEnv)
			if key == "" {
				continue
			}
			pid, ok := providerIDs[role.Provider]
			if !ok {
				pid = newID()
				providerIDs[role.Provider] = pid
				if err := q.InsertLLMProvider(ctx, store.InsertLLMProviderParams{ID: pid, Name: "Anthropic",
					Protocol: string(llm.ProtocolAnthropic), BaseUrl: strings.TrimRight(prov.BaseURL, "/"), ApiKey: key,
					CreatedAt: now, UpdatedAt: now}); err != nil {
					return err
				}
			}
			mid := newID()
			maxTokens := role.MaxTokens
			if maxTokens <= 0 {
				maxTokens = 8000
			}
			if err := q.InsertLLMModel(ctx, store.InsertLLMModelParams{ID: mid, ProviderID: pid, Name: role.Model,
				Model: role.Model, MaxTokens: int64(maxTokens), Effort: role.Effort, CreatedAt: now, UpdatedAt: now}); err != nil {
				return err
			}
			roles[name] = mid
		}

		if legacyAI.BaseURL != "" && legacyAI.APIKey != "" && legacyAI.Model != "" {
			pid, mid := newID(), newID()
			if err := q.InsertLLMProvider(ctx, store.InsertLLMProviderParams{ID: pid, Name: "AI 解读",
				Protocol: string(llm.ProtocolOpenAI), BaseUrl: legacyAI.BaseURL, ApiKey: legacyAI.APIKey,
				CreatedAt: now, UpdatedAt: now}); err != nil {
				return err
			}
			if err := q.InsertLLMModel(ctx, store.InsertLLMModelParams{ID: mid, ProviderID: pid, Name: legacyAI.Model,
				Model: legacyAI.Model, MaxTokens: int64(legacyAI.MaxTokens), Temperature: legacyAI.Temperature,
				CreatedAt: now, UpdatedAt: now}); err != nil {
				return err
			}
			roles[string(llm.RoleExplain)] = mid
			// The connection details now live on the model; keep only what the explanation settings own.
			cleaned, _ := json.Marshal(AIConfig{Enabled: legacyAI.Enabled, AppToken: legacyAI.AppToken})
			if err := put(aiSettingKey, string(cleaned)); err != nil {
				return err
			}
		}

		if len(roles) > 0 {
			if err := saveRoles(ctx, q, roles); err != nil {
				return err
			}
		}
		limits := defaultLLMLimits()
		if l := legacy.Limits; l.MaxConcurrency > 0 {
			limits = LLMLimits{MaxConcurrency: l.MaxConcurrency, RPS: l.RPS, DailyTokenBudget: l.DailyTokenBudget}
		}
		raw, _ := json.Marshal(limits)
		if err := put(llmLimitsKey, string(raw)); err != nil {
			return err
		}
		return put(llmSeededKey, "1")
	})
}

func isRole(name string) bool {
	for _, r := range llmRoleNames {
		if string(r) == name {
			return true
		}
	}
	return false
}

func boolInt(b bool) int64 {
	if b {
		return 1
	}
	return 0
}

// agentVision says whether the model bound to the assistant role can look at pictures.
func (s *Service) agentVision(ctx context.Context) bool {
	q := s.reader()
	roles, err := loadRoles(ctx, q)
	if err != nil {
		return false
	}
	mid, ok := roles[string(llm.RoleAgent)]
	if !ok {
		return false
	}
	m, err := q.GetLLMModel(ctx, mid)
	return err == nil && m.Vision != 0
}
