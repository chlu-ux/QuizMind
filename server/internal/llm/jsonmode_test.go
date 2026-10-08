package llm

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestExtractJSON(t *testing.T) {
	for _, in := range []string{
		`{"a":1}`,
		"```json\n{\"a\":1}\n```",
		"Here you go: {\"a\":1} Hope it helps.",
	} {
		got, err := ExtractJSON(in)
		require.NoError(t, err, in)
		assert.JSONEq(t, `{"a":1}`, string(got), in)
	}
	_, err := ExtractJSON("sorry, I cannot")
	assert.Error(t, err)
}

func TestPromptForJSONKeepsSystemFirst(t *testing.T) {
	p := PromptForJSON("SYSTEM", map[string]any{"type": "object"})
	assert.Contains(t, p, "SYSTEM")
	assert.Contains(t, p, `{"type":"object"}`)
	assert.Equal(t, 0, indexOf(p, "SYSTEM"))
}

func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}
