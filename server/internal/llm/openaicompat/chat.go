// Package openaicompat makes one-shot chat completion calls against any
// OpenAI-compatible endpoint. The explanation feature streams on the client;
// the server only uses this to check that a saved configuration works.
package openaicompat

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Chat sends one user message to {baseURL}/chat/completions and returns the
// reply text. baseURL includes the version segment, e.g. https://api.openai.com/v1.
func Chat(ctx context.Context, hc *http.Client, baseURL, apiKey, model, prompt string, maxTokens int) (string, error) {
	if hc == nil {
		hc = &http.Client{Timeout: 30 * time.Second}
	}
	body, _ := json.Marshal(map[string]any{
		"model":      model,
		"max_tokens": maxTokens,
		"messages":   []map[string]string{{"role": "user", "content": prompt}},
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(baseURL, "/")+"/chat/completions", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+apiKey)
	resp, err := hc.Do(req)
	if err != nil {
		return "", fmt.Errorf("cannot reach %s: %w", baseURL, err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode/100 != 2 {
		return "", fmt.Errorf("endpoint returned %d: %s", resp.StatusCode, snippet(raw))
	}
	var out struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(raw, &out); err != nil || len(out.Choices) == 0 {
		return "", fmt.Errorf("unexpected response: %s", snippet(raw))
	}
	return out.Choices[0].Message.Content, nil
}

func snippet(b []byte) string {
	s := strings.TrimSpace(string(b))
	if r := []rune(s); len(r) > 200 {
		s = string(r[:200]) + "…"
	}
	return s
}
