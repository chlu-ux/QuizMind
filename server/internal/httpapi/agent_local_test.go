package httpapi_test

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/chlu-ux/quizmind/server/internal/llm/fake"
)

func TestAgentLocalSpec(t *testing.T) {
	s := newServer(t)
	s.appPost(t, "/api/v1/agent/local-spec", "", "", 405, nil) // it is a GET

	get := func(token string, want int, out any) {
		t.Helper()
		resp := s.agentReq(t, "GET", "/api/v1/agent/local-spec", token, "")
		defer resp.Body.Close()
		require.Equal(t, want, resp.StatusCode)
		if out != nil {
			require.NoError(t, json.NewDecoder(resp.Body).Decode(out))
		}
	}
	get("anything", 401, nil) // no access token has been set yet

	s.do(t, "PUT", "/admin/ai", `{"enabled":false,"app_token":"`+appToken+`"}`, 200, nil)
	get(appToken, 404, nil) // no model bound

	var provider, model struct{ ID string }
	s.do(t, "POST", "/admin/llm/providers", `{"name":"Gateway","protocol":"anthropic","base_url":"https://llm.example/anthropic","api_key":"sk-gateway-1"}`, 201, &provider)
	s.do(t, "POST", "/admin/llm/models", `{"provider_id":"`+provider.ID+`","model":"gw-model","effort":"low","vision":true}`, 201, &model)
	s.do(t, "PUT", "/admin/llm/roles", `{"agent":"`+model.ID+`"}`, 200, nil)

	get("wrong", 401, nil)
	var spec struct {
		Version string
		Prompt  string
		Tools   []struct {
			Name        string
			Description string
			InputSchema map[string]any `json:"input_schema"`
		}
		Limits struct {
			MaxRounds        int    `json:"max_rounds"`
			MaxDraftsPerChat int    `json:"max_drafts_per_chat"`
			WrapUpNudge      string `json:"wrap_up_nudge"`
		}
		Model struct {
			BaseURL   string `json:"base_url"`
			APIKey    string `json:"api_key"`
			Model     string
			MaxTokens int `json:"max_tokens"`
			Effort    string
			Vision    bool
		}
		DedupeThreshold float64 `json:"dedupe_threshold"`
	}
	get(appToken, 200, &spec)
	assert.Equal(t, "https://llm.example/anthropic", spec.Model.BaseURL)
	assert.Equal(t, "sk-gateway-1", spec.Model.APIKey)
	assert.Equal(t, "gw-model", spec.Model.Model)
	assert.Equal(t, "low", spec.Model.Effort)
	assert.True(t, spec.Model.Vision)
	assert.Positive(t, spec.Model.MaxTokens)
	assert.Contains(t, spec.Prompt, "propose_questions")
	assert.Contains(t, spec.Prompt, "只有用户明确要求时才出题")
	assert.Positive(t, spec.Limits.MaxRounds)
	assert.Equal(t, 30, spec.Limits.MaxDraftsPerChat)
	assert.NotEmpty(t, spec.Limits.WrapUpNudge)
	assert.Positive(t, spec.DedupeThreshold)
	assert.Contains(t, spec.Version, "agent.v1-")

	var names []string
	for _, tl := range spec.Tools {
		names = append(names, tl.Name)
		assert.NotEmpty(t, tl.Description, tl.Name)
		assert.Equal(t, "object", tl.InputSchema["type"], tl.Name)
		if r, has := tl.InputSchema["required"]; has {
			assert.NotEmpty(t, r, "%s: an empty required list is left out, not sent as null", tl.Name)
		}
	}
	// The apps run these on the library they hold; attachments are the server's alone.
	assert.Equal(t, []string{"list_outline", "search_lessons", "get_lesson", "search_questions", "pick_questions",
		"get_weak_points", "propose_questions", "list_drafts"}, names)
}

func TestAgentUploadQuestions(t *testing.T) {
	s, lesson := createFixture(t, fake.Script())
	const id1, id2 = "01HX0000000000000000CLIENT1", "01HX0000000000000000CLIENT2"
	item := func(id, stem, quote string) map[string]any {
		q := q1(stem, 0)
		q["source_quote"] = quote
		q["id"], q["lesson_id"], q["conversation_id"], q["device_id"], q["model"] = id, lesson, "conv-offline", "phone", "deepseek-flash"
		return q
	}
	post := func(token string, want int, out any, qs ...map[string]any) {
		t.Helper()
		b, _ := json.Marshal(map[string]any{"questions": qs})
		s.appPost(t, "/api/v1/agent/questions", token, string(b), want, out)
	}
	type result struct {
		ID       string
		OK       bool
		Status   string
		Verified bool
		Error    string
	}
	var out struct{ Results []result }

	post("", 401, nil, item(id1, "关于读写锁的并发特性，下列哪项描述是正确的？", realQuote))
	post("wrong", 401, nil, item(id1, "关于读写锁的并发特性，下列哪项描述是正确的？", realQuote))
	post(appToken, 400, nil) // nothing to upload
	bad := item(id1, "关于读写锁的并发特性，下列哪项描述是正确的？", realQuote)
	bad["lesson_id"] = ""
	post(appToken, 400, nil, bad)

	var before struct {
		Items []struct{ ID string }
	}
	s.do(t, "GET", "/api/v1/sync/questions?since=0", "", 200, &before)

	// A good one is stored adopted and published at once; a fabricated quote is refused with a reason.
	post(appToken, 200, &out,
		item(id1, "关于读写锁的并发特性，下列哪项描述是正确的？", realQuote),
		item(id2, "读写锁中读者与写者之间的关系是怎样的？", "这句话在讲义里根本不存在，是模型编出来的"))
	require.Len(t, out.Results, 2)
	assert.Equal(t, result{ID: id1, OK: true, Status: "published"}, out.Results[0])
	assert.False(t, out.Results[1].OK)
	assert.Equal(t, id2, out.Results[1].ID)
	assert.Contains(t, out.Results[1].Error, "source_quote")

	// The question carries the device's id into the next sync, so the device finds its own row again.
	var after struct {
		Items []struct {
			ID    string
			Stem  string
			Bank  string `json:"bank_id"`
			Chunk string `json:"chunk_id"`
		}
	}
	s.do(t, "GET", "/api/v1/sync/questions?since=0", "", 200, &after)
	require.Len(t, after.Items, len(before.Items)+1)
	var found bool
	for _, q := range after.Items {
		if q.ID == id1 {
			found = true
			assert.Equal(t, lesson, q.Chunk)
		}
	}
	assert.True(t, found, "the uploaded question is synced under the device's id")

	// Sending it again changes nothing and reports the same outcome.
	post(appToken, 200, &out, item(id1, "关于读写锁的并发特性，下列哪项描述是正确的？", realQuote))
	assert.Equal(t, result{ID: id1, OK: true, Status: "published"}, out.Results[0])
	s.do(t, "GET", "/api/v1/sync/questions?since=0", "", 200, &after)
	assert.Len(t, after.Items, len(before.Items)+1)

	// The same question under another id is a duplicate of the bank.
	post(appToken, 200, &out, item(id2, "关于读写锁的并发特性，下列哪项描述是正确的？", realQuote))
	assert.False(t, out.Results[0].OK)
	assert.Contains(t, out.Results[0].Error, "重复")

	// The accept / discard calls of the apps work on it as on any question of the assistant.
	var res struct{ Status string }
	s.appPost(t, "/api/v1/agent/drafts/"+id1+"/discard", appToken, "", 200, &res)
	assert.Equal(t, "rejected", res.Status)
	post(appToken, 200, &out, item(id1, "关于读写锁的并发特性，下列哪项描述是正确的？", realQuote))
	assert.Equal(t, "rejected", out.Results[0].Status, "an upload retried after the learner took the question back does not revive it")
	s.appPost(t, "/api/v1/agent/drafts/"+id1+"/accept", appToken, "", 200, &res)
	assert.Equal(t, "published", res.Status)
}

func TestAgentUsageReportedByApps(t *testing.T) {
	s := newServer(t)
	s.do(t, "PUT", "/admin/ai", `{"enabled":false,"app_token":"`+appToken+`"}`, 200, nil)
	now := time.Now().UnixMilli()
	rec := func(id, role string) string {
		return fmt.Sprintf(`{"id":%q,"role":%q,"question_id":"conv-offline","device_id":"phone","model":"deepseek-flash",`+
			`"input_tokens":900,"output_tokens":300,"ok":true,"created_at":%d}`, id, role, now)
	}
	s.appPost(t, "/api/v1/ai/usage", appToken, "["+rec("u1", "stranger")+"]", 400, nil)
	var res struct{ Accepted int }
	s.appPost(t, "/api/v1/ai/usage", appToken, "["+rec("u1", "agent")+","+rec("u2", "")+"]", 200, &res)
	assert.Equal(t, 2, res.Accepted)

	var usage []struct {
		Source, Role string
		Calls        int64
	}
	s.do(t, "GET", "/admin/usage", "", 200, &usage)
	roles := map[string]int64{}
	for _, u := range usage {
		assert.Equal(t, "client", u.Source)
		roles[u.Role] += u.Calls
	}
	assert.Equal(t, map[string]int64{"agent": 1, "explain": 1}, roles)
}
