package agent

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/chlu-ux/quizmind/server/internal/llm"
)

// Brief is what the learner was looking at when a conversation began, as the model is told.
type Brief struct {
	// Text goes in front of the learner's first message of the conversation. The instructions
	// (SystemPrompt) never change; this is part of what the learner said.
	Text string
	// Known are the ids of the lessons and questions in Text, which the model may link to.
	Known []string
}

// NewBrief writes the brief for a conversation that begins at [at] with [c]. A lesson or question
// that is not in the library is left out.
func NewBrief(ctx context.Context, lib Library, c Context, at time.Time) (Brief, error) {
	s := newSnapshot(lib)
	var sb strings.Builder
	var known []string
	sb.WriteString("<context>\n")
	fmt.Fprintf(&sb, "对话开始于 %s。\n", at.Format("2006年1月2日"))
	if c.LessonID != "" {
		l, err := s.Lesson(ctx, c.LessonID)
		if err != nil {
			return Brief{}, err
		}
		if l != nil {
			known = append(known, l.ID)
			// No more of it than get_lesson would give: the brief is not counted in the history's budget.
			fmt.Fprintf(&sb, "用户正在阅读这一节讲义：\n<lesson id=%q path=%q>\n%s\n</lesson>\n", l.ID, l.HeadingPath, clip(l.Text, maxToolResult))
		}
	}
	if c.Question != nil {
		questions, err := s.Questions(ctx)
		if err != nil {
			return Brief{}, err
		}
		for _, q := range questions {
			if q.ID != c.Question.ID {
				continue
			}
			known = append(known, q.ID, q.LessonID)
			sb.WriteString("用户正在看这道题：\n")
			fmt.Fprintf(&sb, "<question id=%q>\n题干：%s\n", q.ID, q.Stem)
			for i, o := range q.Options {
				fmt.Fprintf(&sb, "%c. %s\n", 'A'+i, o)
			}
			fmt.Fprintf(&sb, "标准答案：%s\n解析：%s\n", letters(q.Answer), q.Explanation)
			if len(c.Question.Selected) > 0 {
				fmt.Fprintf(&sb, "用户选了：%s\n", letters(c.Question.Selected))
			}
			if q.LessonID != "" {
				fmt.Fprintf(&sb, "出自小节 lesson_id=%s\n", q.LessonID)
			}
			sb.WriteString("</question>\n")
			break
		}
	}
	if c.BankID != "" {
		fmt.Fprintf(&sb, "用户当前所在的题库 bank_id=%s；工具默认只在这个题库里查。\n", c.BankID)
	}
	sb.WriteString("</context>")
	return Brief{Text: sb.String(), Known: known}, nil
}

// PutToday tells the model the date in the newest message when the conversation began on another day
// than [now], so it does not take the day the brief gives for today. It goes last, where it costs no cache.
func PutToday(msgs []llm.Message, began, now time.Time) {
	day := func(t time.Time) string { return t.Format("2006年1月2日") }
	if len(msgs) == 0 || day(began) == day(now) {
		return
	}
	last := &msgs[len(msgs)-1]
	last.Blocks = append(last.Blocks, llm.Block{Kind: llm.BlockText, Text: "（今天是 " + day(now) + "。）"})
}

// PutBrief puts [text] in front of the first message's words, after any pictures it shows. A brief that
// is empty changes nothing.
func PutBrief(msgs []llm.Message, text string) {
	if text == "" || len(msgs) == 0 {
		return
	}
	bs := msgs[0].Blocks
	for i := len(bs) - 1; i >= 0; i-- {
		if bs[i].Kind == llm.BlockText {
			bs[i].Text = text + "\n\n" + bs[i].Text
			return
		}
	}
}
