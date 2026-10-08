package httpapi

import (
	"encoding/json"
	"fmt"
	"net/http"
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
