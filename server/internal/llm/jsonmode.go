package llm

import (
	"encoding/json"
	"fmt"
	"strings"
)

// PromptForJSON returns a system prompt that asks for JSON matching schema in plain text. It is the
// fallback for endpoints that do not support structured outputs: the model is told the shape and the
// reply is parsed with ExtractJSON.
func PromptForJSON(system string, schema map[string]any) string {
	raw, _ := json.Marshal(schema)
	return system + "\n\nReply with ONE JSON object that matches this JSON Schema, and nothing else: no explanation, " +
		"no Markdown code fence.\n" + string(raw)
}

// ExtractJSON returns the JSON object in a model reply that may carry a code fence or a sentence
// around it. Only the outermost {...} is taken; whether it is valid is left to the caller's Unmarshal.
func ExtractJSON(text string) ([]byte, error) {
	text = strings.TrimSpace(text)
	start := strings.IndexByte(text, '{')
	end := strings.LastIndexByte(text, '}')
	if start < 0 || end < start {
		return nil, fmt.Errorf("the reply contains no JSON object")
	}
	return []byte(text[start : end+1]), nil
}
