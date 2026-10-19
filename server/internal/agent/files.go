package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
)

// filePage is how much of a file one read_attachment call returns; with the wrapper it stays under
// maxToolResult.
const filePage = 5000

// ErrNoFile means the file does not exist or belongs to another conversation.
var ErrNoFile = errors.New("no such file")

// File is a text file the learner gave this conversation.
type File struct {
	ID    string
	Name  string
	Chars int
}

// FileReader gives the text of a file. It must answer ErrNoFile for ids outside the conversation.
type FileReader interface {
	Text(ctx context.Context, id string) (string, error)
}

func toolReadAttachment(r FileReader, files []File) *tool {
	type args struct {
		AttachmentID string `json:"attachment_id"`
		Offset       int    `json:"offset"`
	}
	byID := make(map[string]File, len(files))
	for _, f := range files {
		byID[f.ID] = f
	}
	return &tool{
		spec: llmSpec("read_attachment",
			fmt.Sprintf("读取用户给你的一个文件，每次最多 %d 字。返回里有 total（全文字数）和 next_offset（下一页从哪里开始，读完为空）。", filePage),
			schema([]string{"attachment_id"}, map[string]any{
				"attachment_id": str("文件 id，见用户消息末尾的“（附件：文件名，字数，id=…）”"),
				"offset":        integer("从第几个字开始读，默认 0"),
			})),
		label: func(_ context.Context, _ *env, raw json.RawMessage) string {
			var a args
			_ = parseArgs(raw, &a)
			if f, ok := byID[a.AttachmentID]; ok {
				return "读取文件「" + clip(f.Name, 20) + "」"
			}
			return "读取文件"
		},
		run: func(ctx context.Context, _ *env, raw json.RawMessage) (any, error) {
			var a args
			if err := parseArgs(raw, &a); err != nil {
				return nil, err
			}
			f, ok := byID[a.AttachmentID]
			if !ok {
				return nil, badArgs("没有 id 为 %q 的文件，请用用户消息里“（附件：……）”给出的 id", a.AttachmentID)
			}
			if a.Offset < 0 {
				return nil, badArgs("offset 不能是负数")
			}
			text, err := r.Text(ctx, f.ID)
			if errors.Is(err, ErrNoFile) {
				return nil, badArgs("文件「%s」已经不存在", f.Name)
			}
			if err != nil {
				return nil, err
			}
			runes := []rune(text)
			if a.Offset >= len(runes) {
				return nil, badArgs("offset 超过了全文长度 %d", len(runes))
			}
			end := min(a.Offset+filePage, len(runes))
			next := ""
			if end < len(runes) {
				next = fmt.Sprintf(` next_offset="%d"`, end)
			}
			// The text is data from the learner, not instructions: the wrapper lets the prompt say so.
			return fmt.Sprintf("<file id=%q name=%q from=\"%d\" to=\"%d\" total=\"%d\"%s>\n%s\n</file>",
				f.ID, f.Name, a.Offset, end, len(runes), next, string(runes[a.Offset:end])), nil
		},
	}
}
