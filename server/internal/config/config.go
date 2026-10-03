// Package config loads the YAML configuration file and environment overrides.
package config

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

type Config struct {
	Listen   string         `yaml:"listen"`
	DataDir  string         `yaml:"data_dir"`
	Auth     AuthConfig     `yaml:"auth"`
	Pipeline PipelineConfig `yaml:"pipeline"`
	LLM      LLMConfig      `yaml:"llm"`
}

type AuthConfig struct {
	// TokenEnv names the environment variable that holds the static bearer token.
	TokenEnv string `yaml:"token_env"`
	Token    string `yaml:"-"`
}

type PipelineConfig struct {
	QuestionsPerChunk int `yaml:"questions_per_chunk"`
	ChunkMinChars     int `yaml:"chunk_min_chars"`
	ChunkMaxChars     int `yaml:"chunk_max_chars"`
	WorkerConcurrency int `yaml:"worker_concurrency"`
	MaxUploadBytes    int `yaml:"max_upload_bytes"`
	// DedupeThreshold is the trigram Jaccard similarity above which a new stem
	// is treated as a near-duplicate of an existing question in the same bank.
	DedupeThreshold float64 `yaml:"dedupe_threshold"`
}

type LLMConfig struct {
	Providers map[string]ProviderConfig `yaml:"providers"`
	Roles     map[string]RoleConfig     `yaml:"roles"`
	Limits    LimitsConfig              `yaml:"limits"`
}

type ProviderConfig struct {
	Type      string `yaml:"type"` // anthropic | openai_compat
	APIKeyEnv string `yaml:"api_key_env"`
	BaseURL   string `yaml:"base_url"`
	// StructuredMode applies to openai_compat only.
	StructuredMode string `yaml:"structured_mode"`
}

type RoleConfig struct {
	Provider  string `yaml:"provider"`
	Model     string `yaml:"model"`
	Effort    string `yaml:"effort"`     // low|medium|high|xhigh|max (Anthropic)
	MaxTokens int    `yaml:"max_tokens"` // output cap per call
}

type LimitsConfig struct {
	MaxConcurrency   int     `yaml:"max_concurrency"`
	RPS              float64 `yaml:"rps"`
	DailyTokenBudget int64   `yaml:"daily_token_budget"`
}

// Default returns the configuration used when no file is provided.
func Default() Config {
	return Config{
		Listen:  "127.0.0.1:8080",
		DataDir: "./data",
		Auth:    AuthConfig{TokenEnv: "QUIZMIND_TOKEN"},
		Pipeline: PipelineConfig{
			QuestionsPerChunk: 3,
			ChunkMinChars:     300,
			ChunkMaxChars:     1500,
			WorkerConcurrency: 2,
			MaxUploadBytes:    2 << 20,
			DedupeThreshold:   0.8,
		},
		LLM: LLMConfig{
			Providers: map[string]ProviderConfig{
				"anthropic_main": {Type: "anthropic", APIKeyEnv: "ANTHROPIC_API_KEY"},
			},
			Roles: map[string]RoleConfig{
				"generator": {Provider: "anthropic_main", Model: "claude-sonnet-5-5", Effort: "medium", MaxTokens: 8000},
			},
			Limits: LimitsConfig{MaxConcurrency: 2, RPS: 2, DailyTokenBudget: 2_000_000},
		},
	}
}

// Load reads path (if non-empty) over the defaults, then applies env overrides.
func Load(path string) (Config, error) {
	cfg := Default()
	if path != "" {
		raw, err := os.ReadFile(path)
		if err != nil {
			return cfg, fmt.Errorf("read config: %w", err)
		}
		if err := yaml.Unmarshal(raw, &cfg); err != nil {
			return cfg, fmt.Errorf("parse config: %w", err)
		}
	}
	if v := os.Getenv("QUIZMIND_LISTEN"); v != "" {
		cfg.Listen = v
	}
	if v := os.Getenv("QUIZMIND_DATA_DIR"); v != "" {
		cfg.DataDir = v
	}
	if cfg.Auth.TokenEnv != "" {
		cfg.Auth.Token = os.Getenv(cfg.Auth.TokenEnv)
	}
	cfg.DataDir = expandHome(cfg.DataDir)
	return cfg, cfg.validate()
}

func (c Config) DBPath() string { return filepath.Join(c.DataDir, "app.db") }

func (c Config) validate() error {
	if c.Pipeline.QuestionsPerChunk < 1 || c.Pipeline.QuestionsPerChunk > 10 {
		return fmt.Errorf("pipeline.questions_per_chunk must be 1..10")
	}
	if c.Pipeline.ChunkMinChars <= 0 || c.Pipeline.ChunkMaxChars < c.Pipeline.ChunkMinChars {
		return fmt.Errorf("pipeline.chunk_min_chars/chunk_max_chars invalid")
	}
	if c.Pipeline.WorkerConcurrency < 1 {
		return fmt.Errorf("pipeline.worker_concurrency must be >= 1")
	}
	if c.Auth.Token == "" && !c.IsLoopback() {
		return fmt.Errorf("listen address %q is not loopback: set the %s environment variable to a bearer token",
			c.Listen, c.Auth.TokenEnv)
	}
	return nil
}

// IsLoopback reports whether the listen address only accepts local connections.
func (c Config) IsLoopback() bool {
	host, _, err := net.SplitHostPort(c.Listen)
	if err != nil {
		return false
	}
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func expandHome(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, strings.TrimPrefix(p, "~"))
		}
	}
	return p
}
