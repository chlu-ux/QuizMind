package agent

import (
	"context"
	"encoding/json"
)

// Draft limits.
const (
	MaxProposePerCall   = 5
	MaxDraftsPerChat    = 20
	draftUnverifiedNote = "未经独立复核（后台没有配置复核模型）"
)

// ProposedQuestion is a question as the model wrote it, before any checking.
type ProposedQuestion struct {
	Type        string   `json:"type"`
	Stem        string   `json:"stem"`
	Options     []string `json:"options"`
	AnswerIndex int      `json:"answer_index"`
	Explanation string   `json:"explanation"`
	Difficulty  int      `json:"difficulty"`
	Tags        []string `json:"tags"`
	SourceQuote string   `json:"source_quote"`
	// Replaces is the draft_id of an earlier draft of this conversation this question takes the place of.
	Replaces string `json:"replaces"`
}

// Draft is a question that passed every check and waits for the learner to accept or discard it.
type Draft struct {
	DraftID     string   `json:"draft_id"`
	LessonID    string   `json:"lesson_id"`
	Type        string   `json:"type"`
	Stem        string   `json:"stem"`
	Options     []string `json:"options"`
	AnswerIndex int      `json:"answer_index"`
	Explanation string   `json:"explanation"`
	Difficulty  int      `json:"difficulty"`
	Tags        []string `json:"tags"`
	SourceQuote string   `json:"source_quote"`
	// Verified says a second model answered the question independently and agreed.
	Verified bool `json:"verified"`
}

// Drafts is sent to the client when new drafts exist.
type Drafts struct {
	Drafts []Draft `json:"drafts"`
}

func (Drafts) EventName() string { return "drafts" }

// ProposeResult is the outcome for one proposed question. Error is written for the model: it says
// what to change so the question can be proposed again.
type ProposeResult struct {
	OK      bool   `json:"ok"`
	DraftID string `json:"draft_id,omitempty"`
	Error   string `json:"error,omitempty"`
	// Draft is set when OK.
	Draft *Draft `json:"-"`
}

// DraftScope says whose conversation a draft belongs to.
type DraftScope struct {
	ConversationID string
	DeviceID       string
}

// Drafter checks and stores the questions the model proposes. It is implemented by the service
// layer, which owns the database and the rules a stored question must meet.
type Drafter interface {
	// Propose checks each question and stores the ones that pass as drafts. The result has one entry
	// per question, in order. An error is a failure of the system, not of a question.
	Propose(ctx context.Context, scope DraftScope, lessonID string, qs []ProposedQuestion) ([]ProposeResult, error)
	// Drafts lists the conversation's drafts that are still waiting for a decision.
	Drafts(ctx context.Context, conversationID string) ([]Draft, error)
}

func toolProposeQuestions(d Drafter, scope DraftScope) *tool {
	type args struct {
		LessonID  string             `json:"lesson_id"`
		Questions []ProposedQuestion `json:"questions"`
	}
	return &tool{
		spec: llmSpec("propose_questions",
			"提出 1–5 道新题，存为草稿，供用户采纳或丢弃。题必须出自 lesson_id 这一节：source_quote 必须逐字摘抄这一节原文里的一句话，答案必须能从原文得出。返回每道题的结果；失败的会说明原因，请按原因修改后重新提出（最多重试两次）。",
			schema([]string{"lesson_id", "questions"}, map[string]any{
				"lesson_id": str("题目依据的小节 id"),
				"questions": map[string]any{
					"type": "array", "description": "1–5 道题",
					"items": map[string]any{
						"type":     "object",
						"required": []string{"type", "stem", "options", "answer_index", "explanation", "source_quote"},
						"properties": map[string]any{
							"type":         map[string]any{"type": "string", "enum": []string{"single", "judge"}, "description": "single 单选（4 个选项）；judge 判断（选项固定为 正确 / 错误）"},
							"stem":         str("题干，要能脱离原文独立成题，不要写“根据上文”"),
							"options":      map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "description": "单选给 4 个选项，不带 A/B/C/D 前缀；判断题传空数组"},
							"answer_index": integer("正确选项的序号，从 0 开始；判断题 0 = 正确，1 = 错误"),
							"explanation":  str("解析，说明为什么对、其他选项为什么错"),
							"difficulty":   integer("难度 1–5"),
							"tags":         map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "description": "最多 3 个知识点标签"},
							"source_quote": str("原文里的一句话，逐字照抄，不要改写"),
							"replaces":     str("可选：本对话里一道旧草稿的 draft_id，新题通过后它会被替换"),
						},
					},
				},
			})),
		label: func(_ context.Context, _ *env, raw json.RawMessage) string {
			var a args
			_ = parseArgs(raw, &a)
			return "生成题目草稿"
		},
		run: func(ctx context.Context, e *env, raw json.RawMessage) (any, error) {
			var a args
			if err := parseArgs(raw, &a); err != nil {
				return nil, err
			}
			if a.LessonID == "" {
				return nil, badArgs("lesson_id 不能为空")
			}
			if n := len(a.Questions); n < 1 || n > MaxProposePerCall {
				return nil, badArgs("questions 需要 1 到 %d 道题，收到 %d 道", MaxProposePerCall, n)
			}
			e.see(a.LessonID)
			results, err := d.Propose(ctx, scope, a.LessonID, a.Questions)
			if err != nil {
				return nil, err
			}
			var made []Draft
			for _, r := range results {
				if r.OK && r.Draft != nil {
					made = append(made, *r.Draft)
				}
			}
			e.addDrafts(made)
			res := map[string]any{"results": results}
			if len(made) > 0 {
				res["note"] = "通过的题已作为草稿展示给用户，等待用户采纳。不要在回答里重复整道题的内容，简要说明即可。"
			}
			return res, nil
		},
	}
}

func toolListDrafts(d Drafter, scope DraftScope) *tool {
	return &tool{
		spec: llmSpec("list_drafts",
			"列出本对话里仍在等用户决定的草稿（draft_id、题干、选项、答案）。用户要求修改、补充或避免重复时先看看已有的草稿。",
			schema(nil, map[string]any{})),
		label: func(context.Context, *env, json.RawMessage) string { return "查看已有草稿" },
		run: func(ctx context.Context, e *env, _ json.RawMessage) (any, error) {
			drafts, err := d.Drafts(ctx, scope.ConversationID)
			if err != nil {
				return nil, err
			}
			if drafts == nil {
				drafts = []Draft{}
			}
			return map[string]any{"drafts": drafts}, nil
		},
	}
}
