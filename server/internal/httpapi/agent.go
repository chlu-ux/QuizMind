package httpapi

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/chlu-ux/quizmind/server/internal/agent"
	"github.com/chlu-ux/quizmind/server/internal/service"
)

// ssePing keeps a quiet stream alive through proxies that drop idle connections.
const ssePing = 15 * time.Second

func bearer(r *http.Request) string {
	return strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
}

func (a *API) agentStatus(w http.ResponseWriter, r *http.Request) {
	st, err := a.svc.AgentStatus(r.Context(), bearer(r))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, st)
}

// agentDrafts lists a conversation's drafts that still wait for a decision.
func (a *API) agentDrafts(w http.ResponseWriter, r *http.Request) {
	drafts, err := a.svc.AgentDrafts(r.Context(), bearer(r), r.URL.Query().Get("conversation_id"))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"drafts": drafts})
}

func (a *API) agentDraftAccept(w http.ResponseWriter, r *http.Request) {
	res, err := a.svc.AcceptAgentDraft(r.Context(), bearer(r), chi.URLParam(r, "id"))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (a *API) agentDraftDiscard(w http.ResponseWriter, r *http.Request) {
	res, err := a.svc.DiscardAgentDraft(r.Context(), bearer(r), chi.URLParam(r, "id"))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

// agentChat answers one chat request as a server-sent event stream. Failures before the first
// event are ordinary HTTP errors; after that they are "error" events.
func (a *API) agentChat(w http.ResponseWriter, r *http.Request) {
	var in service.AgentChatRequest
	r.Body = http.MaxBytesReader(w, r.Body, 256<<10)
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	run, err := a.svc.StartAgentChat(r.Context(), bearer(r), in)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "streaming is not supported")
		return
	}
	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-store")
	h.Set("X-Accel-Buffering", "no") // reverse proxies must not hold the stream back
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	var mu sync.Mutex // the ping goroutine and the answer both write
	write := func(s string) {
		mu.Lock()
		defer mu.Unlock()
		_, _ = fmt.Fprint(w, s)
		flusher.Flush()
	}
	done := make(chan struct{})
	pinged := make(chan struct{})
	go func() {
		defer close(pinged)
		t := time.NewTicker(ssePing)
		defer t.Stop()
		for {
			select {
			case <-t.C:
				write(": ping\n\n")
			case <-done:
				return
			}
		}
	}()

	run(r.Context(), func(ev agent.Event) {
		b, err := json.Marshal(ev)
		if err != nil {
			return
		}
		write("event: " + ev.EventName() + "\ndata: " + string(b) + "\n\n")
	})
	close(done)
	<-pinged
}

func (a *API) agentConversations(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	page, err := a.svc.ListAgentConversations(r.Context(), bearer(r), q.Get("mode"), int64(intParam(r, "before", 0)), intParam(r, "limit", 30))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, page)
}

func (a *API) agentConversation(w http.ResponseWriter, r *http.Request) {
	c, err := a.svc.GetAgentConversation(r.Context(), bearer(r), chi.URLParam(r, "id"))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, c)
}

func (a *API) agentConversationRename(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Title string `json:"title"`
	}
	if !decode(w, r, &in) {
		return
	}
	if err := a.svc.RenameAgentConversation(r.Context(), bearer(r), chi.URLParam(r, "id"), in.Title); err != nil {
		a.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) agentConversationDelete(w http.ResponseWriter, r *http.Request) {
	if err := a.svc.DeleteAgentConversation(r.Context(), bearer(r), chi.URLParam(r, "id")); err != nil {
		a.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// agentAttachmentUpload takes one file for a conversation: multipart fields conversation_id and file.
func (a *API) agentAttachmentUpload(w http.ResponseWriter, r *http.Request) {
	limit := int64(service.MaxAgentTextBytes) + 1<<20 // headroom for multipart framing
	r.Body = http.MaxBytesReader(w, r.Body, limit)
	if err := r.ParseMultipartForm(limit); err != nil {
		writeError(w, http.StatusRequestEntityTooLarge, "文件太大了，请截取需要的部分再上传")
		return
	}
	file, header, err := r.FormFile("file")
	if err != nil {
		writeError(w, http.StatusBadRequest, `multipart field "file" is required`)
		return
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, int64(service.MaxAgentTextBytes)+1))
	if err != nil {
		writeError(w, http.StatusBadRequest, "could not read upload")
		return
	}
	v, err := a.svc.UploadAgentAttachment(r.Context(), bearer(r), r.FormValue("conversation_id"), header.Filename, data)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, v)
}

func (a *API) agentAttachmentGet(w http.ResponseWriter, r *http.Request) {
	att, err := a.svc.GetAgentAttachment(r.Context(), bearer(r), chi.URLParam(r, "id"))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	body, ctype := att.Data, att.Mime
	if att.Kind == "text" {
		body, ctype = []byte(att.Text), "text/plain; charset=utf-8"
	}
	h := w.Header()
	h.Set("Content-Type", ctype)
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Content-Security-Policy", "default-src 'none'; sandbox")
	h.Set("Cache-Control", "private, no-store")
	h.Set("Content-Length", strconv.Itoa(len(body)))
	_, _ = w.Write(body)
}

func (a *API) agentAttachmentDelete(w http.ResponseWriter, r *http.Request) {
	if err := a.svc.DeleteAgentAttachment(r.Context(), bearer(r), chi.URLParam(r, "id")); err != nil {
		a.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
