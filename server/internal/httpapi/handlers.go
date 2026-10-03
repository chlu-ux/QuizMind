package httpapi

import (
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/chlu-ux/quizmind/server/internal/service"
)

func (a *API) listBanks(w http.ResponseWriter, r *http.Request) {
	banks, err := a.svc.ListBanks(r.Context())
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, banks)
}

func (a *API) createBank(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Title       string `json:"title"`
		Description string `json:"description"`
	}
	if !decode(w, r, &in) {
		return
	}
	b, err := a.svc.CreateBank(r.Context(), in.Title, in.Description)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, b)
}

func (a *API) listDocuments(w http.ResponseWriter, r *http.Request) {
	docs, err := a.svc.ListDocuments(r.Context())
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, docs)
}

func (a *API) uploadDocument(w http.ResponseWriter, r *http.Request) {
	limit := int64(a.svc.Cfg.Pipeline.MaxUploadBytes) + 1<<20 // headroom for multipart framing
	r.Body = http.MaxBytesReader(w, r.Body, limit)
	if err := r.ParseMultipartForm(limit); err != nil {
		writeError(w, http.StatusRequestEntityTooLarge, "upload too large or malformed")
		return
	}
	file, header, err := r.FormFile("file")
	if err != nil {
		writeError(w, http.StatusBadRequest, `multipart field "file" is required`)
		return
	}
	defer file.Close()
	content, err := io.ReadAll(io.LimitReader(file, int64(a.svc.Cfg.Pipeline.MaxUploadBytes)+1))
	if err != nil {
		writeError(w, http.StatusBadRequest, "could not read upload")
		return
	}
	res, err := a.svc.ImportDocument(r.Context(), r.FormValue("bank_id"), header.Filename, content)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	status := http.StatusOK
	if res.Created {
		status = http.StatusCreated
	}
	writeJSON(w, status, res)
}

func (a *API) getDocument(w http.ResponseWriter, r *http.Request) {
	d, err := a.svc.GetDocument(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, d)
}

func (a *API) retryDocument(w http.ResponseWriter, r *http.Request) {
	n, err := a.svc.RetryDocument(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]int64{"requeued": n})
}

func (a *API) listJobs(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	jobs, err := a.svc.ListJobs(r.Context(), q.Get("status"), q.Get("document_id"), intParam(r, "limit", 100))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, jobs)
}

func (a *API) retryJob(w http.ResponseWriter, r *http.Request) {
	if err := a.svc.RetryJob(r.Context(), chi.URLParam(r, "id")); err != nil {
		a.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) listQuestions(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	page, err := a.svc.ListQuestions(r.Context(), service.QuestionFilter{
		Status: q.Get("status"), BankID: q.Get("bank_id"), DocumentID: q.Get("document_id"),
		Limit: intParam(r, "limit", 50), Offset: intParam(r, "offset", 0),
	})
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, page)
}

func (a *API) getQuestion(w http.ResponseWriter, r *http.Request) {
	q, err := a.svc.GetQuestion(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, q)
}

func (a *API) editQuestion(w http.ResponseWriter, r *http.Request) {
	var in service.QuestionEdit
	if !decode(w, r, &in) {
		return
	}
	q, err := a.svc.EditQuestion(r.Context(), chi.URLParam(r, "id"), in)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, q)
}

func (a *API) approveQuestion(w http.ResponseWriter, r *http.Request) {
	q, err := a.svc.ApproveQuestion(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, q)
}

func (a *API) rejectQuestion(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Note string `json:"note"`
	}
	if r.ContentLength != 0 && !decode(w, r, &in) {
		return
	}
	q, err := a.svc.RejectQuestion(r.Context(), chi.URLParam(r, "id"), in.Note)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, q)
}

func (a *API) bulkReview(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Action string   `json:"action"`
		IDs    []string `json:"ids"`
		Note   string   `json:"note"`
	}
	if !decode(w, r, &in) {
		return
	}
	res, err := a.svc.BulkReview(r.Context(), in.Action, in.IDs, in.Note)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (a *API) usage(w http.ResponseWriter, r *http.Request) {
	rows, err := a.svc.Usage(r.Context(), intParam(r, "days", 30))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

// streamEvents pushes job and document progress as server-sent events.
func (a *API) streamEvents(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "streaming unsupported")
		return
	}
	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-cache")
	h.Set("Connection", "keep-alive")
	h.Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, ": connected\n\n")
	flusher.Flush()

	ch, cancel := a.hub.Subscribe()
	defer cancel()
	heartbeat := time.NewTicker(25 * time.Second)
	defer heartbeat.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-a.hub.Done():
			return
		case ev := <-ch:
			b, _ := jsonMarshal(ev)
			fmt.Fprintf(w, "event: %s\ndata: %s\n\n", ev.Type, b)
			flusher.Flush()
		case <-heartbeat.C:
			fmt.Fprint(w, ": ping\n\n")
			flusher.Flush()
		}
	}
}

// ---- app API (/api/v1) ----

func (a *API) appBanks(w http.ResponseWriter, r *http.Request) {
	banks, err := a.svc.AppBanks(r.Context())
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, banks)
}

func (a *API) syncQuestions(w http.ResponseWriter, r *http.Request) {
	page, err := a.svc.SyncQuestions(r.Context(), int64(intParam(r, "since", 0)), intParam(r, "limit", 500))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, page)
}

func (a *API) syncStatesDown(w http.ResponseWriter, r *http.Request) {
	page, err := a.svc.SyncStates(r.Context(), int64(intParam(r, "since", 0)), intParam(r, "limit", 500))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, page)
}

func (a *API) syncAttemptsUp(w http.ResponseWriter, r *http.Request) {
	var in []service.AttemptIn
	if !decode(w, r, &in) {
		return
	}
	res, err := a.svc.UploadAttempts(r.Context(), in)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (a *API) syncStatesUp(w http.ResponseWriter, r *http.Request) {
	var in []service.StateIn
	if !decode(w, r, &in) {
		return
	}
	res, err := a.svc.UploadStates(r.Context(), in)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (a *API) syncSessionsDown(w http.ResponseWriter, r *http.Request) {
	page, err := a.svc.SyncSessions(r.Context(), int64(intParam(r, "since", 0)), intParam(r, "limit", 100))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, page)
}

func (a *API) syncSessionsUp(w http.ResponseWriter, r *http.Request) {
	var in []service.SessionIn
	if !decode(w, r, &in) {
		return
	}
	res, err := a.svc.UploadSessions(r.Context(), in)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (a *API) flagQuestion(w http.ResponseWriter, r *http.Request) {
	res, err := a.svc.FlagQuestion(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}
