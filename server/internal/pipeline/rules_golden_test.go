package pipeline

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// The rules a question must meet are also applied by the apps, which check what the assistant writes on
// the device. Both sides run the cases in api/testdata/question_rules.json, so they cannot drift apart
// unnoticed: change a rule here and the apps' copy fails (app/test/local_agent_test.dart) until it follows.
type goldenRules struct {
	Lesson   string `json:"lesson"`
	Validate []struct {
		Name     string            `json:"name"`
		Question GeneratedQuestion `json:"question"`
		Error    string            `json:"error"`
		Options  []string          `json:"options"`
		Tags     []string          `json:"tags"`
		Diff     int               `json:"difficulty"`
	} `json:"validate"`
	Dedupe []struct {
		Name      string  `json:"name"`
		Threshold float64 `json:"threshold"`
		Existing  []struct {
			Stem    string   `json:"stem"`
			Options []string `json:"options"`
		} `json:"existing"`
		Candidate struct {
			Stem    string   `json:"stem"`
			Options []string `json:"options"`
		} `json:"candidate"`
		Duplicate bool `json:"duplicate"`
	} `json:"dedupe"`
}

func loadGolden(t *testing.T) goldenRules {
	t.Helper()
	raw, err := os.ReadFile("../../../api/testdata/question_rules.json")
	require.NoError(t, err)
	var g goldenRules
	require.NoError(t, json.Unmarshal(raw, &g))
	require.NotEmpty(t, g.Validate)
	return g
}

func TestGoldenValidateQuestion(t *testing.T) {
	g := loadGolden(t)
	for _, c := range g.Validate {
		t.Run(c.Name, func(t *testing.T) {
			v, err := ValidateQuestion(c.Question, g.Lesson)
			if c.Error != "" {
				require.Error(t, err)
				assert.Contains(t, err.Error(), c.Error)
				return
			}
			require.NoError(t, err)
			if c.Options != nil {
				assert.Equal(t, c.Options, v.Options)
			}
			if c.Tags != nil {
				assert.Equal(t, c.Tags, v.Tags)
			}
			if c.Diff != 0 {
				assert.Equal(t, c.Diff, v.Difficulty)
			}
		})
	}
}

func TestGoldenDedupe(t *testing.T) {
	g := loadGolden(t)
	for _, c := range g.Dedupe {
		t.Run(c.Name, func(t *testing.T) {
			var existing []Existing
			for i, e := range c.Existing {
				existing = append(existing, Existing{ID: string(rune('a' + i)), Stem: e.Stem, Options: e.Options, Hash: ContentHash(e.Stem, e.Options)})
			}
			d := NewDeduper(existing, c.Threshold)
			_, dup := d.Check("new", ValidQuestion{Stem: c.Candidate.Stem, Options: c.Candidate.Options, Hash: ContentHash(c.Candidate.Stem, c.Candidate.Options)})
			assert.Equal(t, c.Duplicate, dup)
		})
	}
}
