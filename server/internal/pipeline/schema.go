package pipeline

import (
	_ "embed"
	"fmt"
	"strings"
)

// PromptVersion is stored with every generated question so quality can be
// compared across prompt revisions.
const PromptVersion = "gen.v1"

//go:embed prompts/generate_system.v1.txt
var generateSystemPrompt string

// GeneratedQuestion is the model's raw output for one question, before any
// validation. All fields are untrusted.
type GeneratedQuestion struct {
	Type        string   `json:"type"`
	Stem        string   `json:"stem"`
	Options     []string `json:"options"`
	AnswerIndex int      `json:"answer_index"`
	Explanation string   `json:"explanation"`
	Difficulty  int      `json:"difficulty"`
	Tags        []string `json:"tags"`
	SourceQuote string   `json:"source_quote"`
}

type generateOutput struct {
	Questions []GeneratedQuestion `json:"questions"`
}

// generateSchema is the JSON Schema the model must satisfy. It sticks to the
// subset structured outputs support (no numeric or length bounds); bounds are
// enforced afterwards by ValidateQuestion.
func generateSchema() map[string]any {
	str := map[string]any{"type": "string"}
	return map[string]any{
		"type":                 "object",
		"additionalProperties": false,
		"required":             []string{"questions"},
		"properties": map[string]any{
			"questions": map[string]any{
				"type": "array",
				"items": map[string]any{
					"type":                 "object",
					"additionalProperties": false,
					"required": []string{"type", "stem", "options", "answer_index",
						"explanation", "difficulty", "tags", "source_quote"},
					"properties": map[string]any{
						"type":         map[string]any{"type": "string", "enum": []string{"single", "judge"}},
						"stem":         str,
						"options":      map[string]any{"type": "array", "items": str},
						"answer_index": map[string]any{"type": "integer"},
						"explanation":  str,
						"difficulty":   map[string]any{"type": "integer"},
						"tags":         map[string]any{"type": "array", "items": str},
						"source_quote": str,
					},
				},
			},
		},
	}
}

func buildUserPrompt(headingPath, chunkText string, n int) string {
	var b strings.Builder
	fmt.Fprintf(&b, "Section path: %s\n\n<excerpt>\n%s\n</excerpt>\n\n", headingPath, chunkText)
	fmt.Fprintf(&b, "Write up to %d questions about this excerpt.", n)
	return b.String()
}
