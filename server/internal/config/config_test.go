package config_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/chlu-ux/quizmind/server/internal/config"
)

func write(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(p, []byte(body), 0o600))
	return p
}

func TestDefaultsAreLoopbackWithoutToken(t *testing.T) {
	t.Setenv("QUIZMIND_TOKEN", "")
	cfg, err := config.Load("")
	require.NoError(t, err)
	assert.True(t, cfg.IsLoopback())
	assert.Equal(t, "claude-sonnet-5-5", cfg.LLM.Roles["generator"].Model)
}

func TestNonLoopbackRequiresToken(t *testing.T) {
	p := write(t, "listen: 0.0.0.0:8080\n")
	t.Setenv("QUIZMIND_TOKEN", "")
	_, err := config.Load(p)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "QUIZMIND_TOKEN")

	t.Setenv("QUIZMIND_TOKEN", "secret")
	cfg, err := config.Load(p)
	require.NoError(t, err)
	assert.Equal(t, "secret", cfg.Auth.Token)
	assert.False(t, cfg.IsLoopback())
}

func TestLoopbackVariants(t *testing.T) {
	t.Setenv("QUIZMIND_TOKEN", "")
	for _, l := range []string{"127.0.0.1:1", "localhost:1", "[::1]:1"} {
		cfg, err := config.Load(write(t, "listen: \""+l+"\"\n"))
		require.NoError(t, err, l)
		assert.True(t, cfg.IsLoopback(), l)
	}
}

func TestYAMLOverridesDefaultsAndEnvOverridesYAML(t *testing.T) {
	t.Setenv("QUIZMIND_TOKEN", "")
	p := write(t, "pipeline:\n  questions_per_chunk: 5\nlisten: 127.0.0.1:9000\n")
	t.Setenv("QUIZMIND_LISTEN", "127.0.0.1:9100")
	cfg, err := config.Load(p)
	require.NoError(t, err)
	assert.Equal(t, 5, cfg.Pipeline.QuestionsPerChunk)
	assert.Equal(t, 1500, cfg.Pipeline.ChunkMaxChars, "unspecified keys keep defaults")
	assert.Equal(t, "127.0.0.1:9100", cfg.Listen)
}

func TestHomeExpansionAndDBPath(t *testing.T) {
	t.Setenv("QUIZMIND_TOKEN", "")
	home, err := os.UserHomeDir()
	require.NoError(t, err)
	cfg, err := config.Load(write(t, "data_dir: ~/quizmind-data\n"))
	require.NoError(t, err)
	assert.Equal(t, filepath.Join(home, "quizmind-data", "app.db"), cfg.DBPath())
}

func TestValidation(t *testing.T) {
	t.Setenv("QUIZMIND_TOKEN", "")
	for name, body := range map[string]string{
		"zero questions": "pipeline:\n  questions_per_chunk: 0\n",
		"too many":       "pipeline:\n  questions_per_chunk: 50\n",
		"bad chunk size": "pipeline:\n  chunk_min_chars: 900\n  chunk_max_chars: 100\n",
		"bad yaml":       "listen: [unclosed\n",
	} {
		_, err := config.Load(write(t, body))
		assert.Error(t, err, name)
	}
	_, err := config.Load("/nonexistent/config.yaml")
	assert.Error(t, err)
}
