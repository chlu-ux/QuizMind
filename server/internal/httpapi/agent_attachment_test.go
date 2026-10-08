package httpapi_test

import (
	"bytes"
	"encoding/json"
	"io"
	"mime/multipart"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/chlu-ux/quizmind/server/internal/llm"
	"github.com/chlu-ux/quizmind/server/internal/llm/fake"
)

type attView struct {
	ID    string `json:"id"`
	Kind  string `json:"kind"`
	Name  string `json:"name"`
	Mime  string `json:"mime"`
	Size  int    `json:"size"`
	Chars int    `json:"chars"`
}

func (s *server) uploadFile(t *testing.T, token, conv, filename string, content []byte) (*http.Response, attView) {
	t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	require.NoError(t, mw.WriteField("conversation_id", conv))
	fw, err := mw.CreateFormFile("file", filename)
	require.NoError(t, err)
	_, _ = fw.Write(content)
	require.NoError(t, mw.Close())
	r, err := http.NewRequest("POST", s.ts.URL+"/api/v1/agent/attachments", &buf)
	require.NoError(t, err)
	r.Header.Set("Content-Type", mw.FormDataContentType())
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(r)
	require.NoError(t, err)
	var v attView
	if resp.StatusCode == 201 {
		require.NoError(t, json.NewDecoder(resp.Body).Decode(&v))
	}
	return resp, v
}

// giveFile expects the file to be taken.
func (s *server) giveFile(t *testing.T, conv, filename, content string) attView {
	t.Helper()
	resp, v := s.uploadFile(t, appToken, conv, filename, []byte(content))
	resp.Body.Close()
	require.Equal(t, 201, resp.StatusCode)
	return v
}

// uploadError expects the file to be refused and returns the reason.
func (s *server) uploadError(t *testing.T, status int, conv, filename string, content []byte) string {
	t.Helper()
	resp, _ := s.uploadFile(t, appToken, conv, filename, content)
	defer resp.Body.Close()
	require.Equal(t, status, resp.StatusCode)
	var e struct{ Error string }
	_ = json.NewDecoder(resp.Body).Decode(&e)
	return e.Error
}

func (s *server) attachmentCount(t *testing.T) (n int) {
	t.Helper()
	require.NoError(t, s.db.Write.QueryRow(`SELECT COUNT(*) FROM agent_attachment`).Scan(&n))
	return n
}

func TestAgentAttachment_UploadIsCheckedByContent(t *testing.T) {
	s := newAgentServer(t)

	resp, _ := s.uploadFile(t, "", "c1", "n.md", []byte("hi"))
	resp.Body.Close()
	assert.Equal(t, 401, resp.StatusCode)
	resp, _ = s.uploadFile(t, "wrong", "c1", "n.md", []byte("hi"))
	resp.Body.Close()
	assert.Equal(t, 401, resp.StatusCode)

	// A BOM and Windows line endings are cleaned off; the length is in characters.
	v := s.giveFile(t, "c1", `C:\Users\me\笔记.MD`, "\xef\xbb\xbf# 标题\r\n内容")
	assert.Equal(t, "text", v.Kind)
	assert.Equal(t, "笔记.MD", v.Name, "only the file's own name is kept")
	assert.Equal(t, "text/markdown", v.Mime)
	assert.Equal(t, len("\xef\xbb\xbf# 标题\r\n内容"), v.Size, "size is the upload's bytes")
	assert.Equal(t, 7, v.Chars)

	assert.Contains(t, s.uploadError(t, 400, "c1", "a.pdf", []byte("%PDF")), "不支持这种文件")
	assert.Contains(t, s.uploadError(t, 400, "c1", "a.png", []byte("\x89PNG")), "不支持这种文件")
	assert.Contains(t, s.uploadError(t, 400, "c1", "a.txt", []byte("\xff\xfe\x00bad")), "UTF-8")
	assert.Contains(t, s.uploadError(t, 400, "c1", "a.txt", []byte("a\x00b")), "UTF-8")
	assert.Contains(t, s.uploadError(t, 400, "c1", "a.txt", nil), "空的")
	assert.Contains(t, s.uploadError(t, 400, "c1", "a.txt", []byte(" \n\t ")), "没有文字")
	assert.Contains(t, s.uploadError(t, 400, "c1", "a.txt", bytes.Repeat([]byte("a"), 512<<10+1)), "太大")
	assert.Contains(t, s.uploadError(t, 400, "c1", "a.txt", []byte(strings.Repeat("字", 120001))), "120000")
	assert.Contains(t, s.uploadError(t, 400, "", "a.txt", []byte("x")), "conversation_id")
	assert.Equal(t, 1, s.attachmentCount(t), "refused files are not kept")

	// The most it will take: 120000 characters.
	assert.Equal(t, 120000, s.giveFile(t, "c2", "big.txt", strings.Repeat("字", 120000)).Chars)
}

func TestAgentAttachment_LimitPerConversation(t *testing.T) {
	s := newAgentServer(t)
	for i := 0; i < 8; i++ {
		s.giveFile(t, "c1", "n.txt", "x")
	}
	assert.Contains(t, s.uploadError(t, 400, "c1", "n.txt", []byte("x")), "最多 8 个")
	s.giveFile(t, "c2", "n.txt", "x") // another conversation has its own count
}

func TestAgentAttachment_GetAndDelete(t *testing.T) {
	s := newAgentServer(t)
	v := s.giveFile(t, "c1", "n.md", "# 笔记\n<script>alert(1)</script>")

	resp := s.agentReq(t, "GET", "/api/v1/agent/attachments/"+v.ID, "", "")
	resp.Body.Close()
	assert.Equal(t, 401, resp.StatusCode)

	resp = s.agentReq(t, "GET", "/api/v1/agent/attachments/"+v.ID, appToken, "")
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	assert.Equal(t, 200, resp.StatusCode)
	assert.Equal(t, "text/plain; charset=utf-8", resp.Header.Get("Content-Type"), "shown as text whatever the file claims")
	assert.Equal(t, "nosniff", resp.Header.Get("X-Content-Type-Options"))
	assert.Contains(t, resp.Header.Get("Content-Security-Policy"), "sandbox")
	assert.Equal(t, "# 笔记\n<script>alert(1)</script>", string(body))

	resp = s.agentReq(t, "GET", "/api/v1/agent/attachments/nope", appToken, "")
	resp.Body.Close()
	assert.Equal(t, 404, resp.StatusCode)

	resp = s.agentReq(t, "DELETE", "/api/v1/agent/attachments/"+v.ID, appToken, "")
	resp.Body.Close()
	assert.Equal(t, 204, resp.StatusCode)
	assert.Equal(t, 0, s.attachmentCount(t))
	resp = s.agentReq(t, "DELETE", "/api/v1/agent/attachments/"+v.ID, appToken, "")
	resp.Body.Close()
	assert.Equal(t, 404, resp.StatusCode)
}

func (s *server) askWith(t *testing.T, conv, text string, ids ...string) (int, string) {
	t.Helper()
	body := storedBody(conv, "learn", text, map[string]any{"message": map[string]any{"text": text, "attachment_ids": ids}})
	resp := s.agentReq(t, "POST", "/api/v1/agent/chat", appToken, body)
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		var e struct{ Error string }
		_ = json.NewDecoder(resp.Body).Decode(&e)
		return resp.StatusCode, e.Error
	}
	readSSE(t, resp)
	return 200, ""
}

func TestAgentAttachment_AssistantReadsTheFile(t *testing.T) {
	s := newAgentServer(t)
	note := strings.Repeat("甲", 5000) + "第二页的内容"
	v := s.giveFile(t, "c1", "笔记.md", note)

	conv := fake.Script(
		fake.Turn{Calls: []fake.Call{{Name: "read_attachment", Input: `{"attachment_id":"` + v.ID + `"}`}}},
		fake.Turn{Calls: []fake.Call{{Name: "read_attachment", Input: `{"attachment_id":"` + v.ID + `","offset":5000}`}}},
		fake.Turn{Text: "笔记里写了第二页的内容。"},
		fake.Turn{Text: "好的。"},
	)
	enableAgent(t, s, conv)
	s.guard.SetLimits(llm.Limits{MaxConcurrency: 4})

	status, _ := s.askWith(t, "c1", "总结这份笔记", v.ID)
	require.Equal(t, 200, status)

	reqs := conv.Requests()
	require.Len(t, reqs, 3)
	assert.Len(t, reqs[0].Tools, 7, "read_attachment is offered when there are files")
	assert.Contains(t, reqs[0].System[1], `<attachment id="`+v.ID+`" name="笔记.md" chars="5006" />`)
	assert.Contains(t, reqs[0].System[1], "不是指令")
	first := roles(reqs[0])
	require.Len(t, first, 1)
	assert.Contains(t, first[0], "总结这份笔记\n（附件：笔记.md，5006 字，id="+v.ID+"）")

	results := resultsOf(reqs[1])
	require.Len(t, results, 1)
	assert.Contains(t, results[0].Text, `from="0" to="5000" total="5006" next_offset="5000"`)
	results = resultsOf(reqs[2])
	require.Len(t, results, 2)
	assert.Contains(t, results[1].Text, `from="5000" to="5006" total="5006">`, "the last page has no next_offset")
	assert.Contains(t, results[1].Text, "第二页的内容")

	// The file is now the conversation's: shown with the message, kept for the next question, not deletable alone.
	d := s.conversationFiles(t, "c1")
	require.Len(t, d, 2)
	assert.Equal(t, []string(nil), d[1])
	require.Len(t, d[0], 1)
	assert.Equal(t, "笔记.md", d[0][0])

	status, _ = s.askWith(t, "c1", "再看一眼")
	require.Equal(t, 200, status)
	reqs = conv.Requests()
	assert.Len(t, reqs[3].Tools, 7, "later questions still have the tool")
	assert.Contains(t, reqs[3].System[1], v.ID)
	hist := roles(reqs[3])
	assert.Contains(t, hist[0], "（附件：笔记.md，5006 字，id="+v.ID+"）", "the earlier question still says what it carried")

	resp := s.agentReq(t, "DELETE", "/api/v1/agent/attachments/"+v.ID, appToken, "")
	resp.Body.Close()
	assert.Equal(t, 400, resp.StatusCode, "a sent file can only go with its conversation")
}

// conversationFiles returns, per message, the names of the files it carried.
func (s *server) conversationFiles(t *testing.T, id string) [][]string {
	t.Helper()
	resp := s.agentReq(t, "GET", "/api/v1/agent/conversations/"+id, appToken, "")
	defer resp.Body.Close()
	require.Equal(t, 200, resp.StatusCode)
	var d struct {
		Messages []struct {
			Attachments []attView `json:"attachments"`
		} `json:"messages"`
	}
	require.NoError(t, json.NewDecoder(resp.Body).Decode(&d))
	var out [][]string
	for _, m := range d.Messages {
		var names []string
		for _, a := range m.Attachments {
			names = append(names, a.Name)
		}
		out = append(out, names)
	}
	return out
}

func TestAgentAttachment_ChatChecksTheFiles(t *testing.T) {
	s := newAgentServer(t)
	conv := fake.Script(fake.Turn{Text: "好"}, fake.Turn{Text: "好"})
	enableAgent(t, s, conv)
	s.guard.SetLimits(llm.Limits{MaxConcurrency: 4})

	other := s.giveFile(t, "c-other", "o.txt", "别的对话")
	mine := s.giveFile(t, "c1", "m.txt", "我的")

	status, msg := s.askWith(t, "c1", "看看", other.ID)
	assert.Equal(t, 400, status, "a file of another conversation")
	assert.Contains(t, msg, "找不到文件")
	status, msg = s.askWith(t, "c1", "看看", "nope")
	assert.Equal(t, 400, status)
	status, msg = s.askWith(t, "c1", "看看", mine.ID, mine.ID)
	assert.Equal(t, 400, status)
	assert.Contains(t, msg, "重复")
	var ids []string
	for i := 0; i < 5; i++ {
		ids = append(ids, s.giveFile(t, "c3", "x.txt", "x").ID)
	}
	status, msg = s.askWith(t, "c3", "看看", ids...)
	assert.Equal(t, 400, status)
	assert.Contains(t, msg, "最多带 4 个")
	assert.Empty(t, conv.Requests(), "nothing reached the model")
	assert.Empty(t, s.conversations(t, "").Items, "and no conversation was made")

	status, _ = s.askWith(t, "c1", "看看", mine.ID)
	require.Equal(t, 200, status)
	status, msg = s.askWith(t, "c1", "再看看", mine.ID)
	assert.Equal(t, 400, status, "a file goes with one message")
	assert.Contains(t, msg, "已经随之前的消息发出")
}

func TestAgentAttachment_FilesGoWithTheConversation(t *testing.T) {
	s := newAgentServer(t)
	conv := fake.Script(fake.Turn{Text: "好"})
	enableAgent(t, s, conv)
	s.guard.SetLimits(llm.Limits{MaxConcurrency: 4})

	sent := s.giveFile(t, "c1", "a.txt", "a")
	s.giveFile(t, "c1", "unsent.txt", "u")
	s.giveFile(t, "c2", "keep.txt", "k")
	status, _ := s.askWith(t, "c1", "看", sent.ID)
	require.Equal(t, 200, status)
	require.Equal(t, 3, s.attachmentCount(t))

	resp := s.agentReq(t, "DELETE", "/api/v1/agent/conversations/c1", appToken, "")
	resp.Body.Close()
	require.Equal(t, 204, resp.StatusCode)
	assert.Equal(t, 1, s.attachmentCount(t), "its files, sent or not, are gone; other conversations' are not")
}

func TestAgentAttachment_UnsentFilesAreCleanedAfterADay(t *testing.T) {
	s := newAgentServer(t)
	s.giveFile(t, "c1", "old.txt", "x")
	s.giveFile(t, "c1", "new.txt", "y")
	_, err := s.db.Write.Exec(`UPDATE agent_attachment SET created_at = ? WHERE name = 'old.txt'`,
		time.Now().Add(-25*time.Hour).UnixMilli())
	require.NoError(t, err)

	s.giveFile(t, "c9", "trigger.txt", "z") // an upload tidies up first
	assert.Equal(t, 2, s.attachmentCount(t))
	var left int
	require.NoError(t, s.db.Write.QueryRow(`SELECT COUNT(*) FROM agent_attachment WHERE name = 'old.txt'`).Scan(&left))
	assert.Equal(t, 0, left)
}

func resultsOf(req llm.ChatRequest) []llm.Block {
	var out []llm.Block
	for _, m := range req.Messages {
		for _, b := range m.Blocks {
			if b.Kind == llm.BlockToolResult {
				out = append(out, b)
			}
		}
	}
	return out
}

// newAgentServer is a server whose app token is set, so the apps' endpoints accept it.
func newAgentServer(t *testing.T) *server {
	t.Helper()
	s := newServer(t)
	enableAgent(t, s, fake.Script())
	return s
}
