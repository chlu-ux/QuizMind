package pipeline

import (
	"context"
	"fmt"

	"github.com/chlu-ux/quizmind/server/internal/llm"
)

// Generator asks a model for candidate questions about one chunk.
type Generator struct {
	LLM       llm.Client
	PerChunk  int
	MaxTokens int
}

// Generate returns the model's raw candidates. Callers must run each through
// ValidateQuestion; nothing here is trusted.
func (g *Generator) Generate(ctx context.Context, headingPath, chunkText string) ([]GeneratedQuestion, llm.Usage, error) {
	var out generateOutput
	usage, err := g.LLM.GenerateJSON(ctx, llm.JSONRequest{
		System:     generateSystemPrompt,
		User:       buildUserPrompt(headingPath, chunkText, g.PerChunk),
		SchemaName: "quiz_questions",
		Schema:     generateSchema(),
		MaxTokens:  g.MaxTokens,
	}, &out)
	if err != nil {
		return nil, usage, fmt.Errorf("generate questions: %w", err)
	}
	// The prompt asks for "up to N"; never accept more than that.
	if len(out.Questions) > g.PerChunk {
		out.Questions = out.Questions[:g.PerChunk]
	}
	return out.Questions, usage, nil
}
