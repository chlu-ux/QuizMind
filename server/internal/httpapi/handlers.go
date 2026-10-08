package httpapi

import (
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
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

func (a *API) getDocumentContent(w http.ResponseWriter, r *http.Request) {
	d, err := a.svc.GetDocumentContent(r.Context(), chi.URLParam(r, "id"))
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
		Status: q.Get("status"), BankID: q.Get("bank_id"), DocumentID: q.Get("document_id"), Search: q.Get("search"),
		Flagged: q.Get("flagged") == "1",
		Limit:   intParam(r, "limit", 50), Offset: intParam(r, "offset", 0),
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

func (a *API) dismissFlags(w http.ResponseWriter, r *http.Request) {
	q, err := a.svc.DismissFlags(r.Context(), chi.URLParam(r, "id"))
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

func (a *API) syncAttemptsDown(w http.ResponseWriter, r *http.Request) {
	page, err := a.svc.SyncAttempts(r.Context(), int64(intParam(r, "since", 0)), intParam(r, "limit", 500))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, page)
}

func (a *API) syncExamsDown(w http.ResponseWriter, r *http.Request) {
	page, err := a.svc.SyncExams(r.Context(), int64(intParam(r, "since", 0)), intParam(r, "limit", 100))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, page)
}

func (a *API) syncExamsUp(w http.ResponseWriter, r *http.Request) {
	var in []service.ExamIn
	if !decode(w, r, &in) {
		return
	}
	res, err := a.svc.UploadExams(r.Context(), in)
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
	// The body is optional: clients from before report reasons send none.
	var in struct {
		Reason string `json:"reason"`
	}
	if r.ContentLength != 0 && !decode(w, r, &in) {
		return
	}
	res, err := a.svc.FlagQuestion(r.Context(), chi.URLParam(r, "id"), in.Reason)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

// ---- AI explanation ----

func (a *API) getAIConfig(w http.ResponseWriter, r *http.Request) {
	v, err := a.svc.AdminAIConfig(r.Context())
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, v)
}

func (a *API) listAINotes(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	page, err := a.svc.ListAINotes(r.Context(), service.AINoteFilter{
		BankID: q.Get("bank_id"), Search: q.Get("search"),
		Limit: intParam(r, "limit", 20), Offset: intParam(r, "offset", 0),
	})
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, page)
}

func (a *API) putAIConfig(w http.ResponseWriter, r *http.Request) {
	var in service.AIConfigUpdate
	if !decode(w, r, &in) {
		return
	}
	v, err := a.svc.SaveAIConfig(r.Context(), in)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, v)
}

// ---- model providers, models and roles ----

func (a *API) getLLMConfig(w http.ResponseWriter, r *http.Request) {
	v, err := a.svc.LLMConfig(r.Context())
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, v)
}

func (a *API) createLLMProvider(w http.ResponseWriter, r *http.Request) {
	var in service.ProviderInput
	if !decode(w, r, &in) {
		return
	}
	v, err := a.svc.CreateProvider(r.Context(), in)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, v)
}

func (a *API) updateLLMProvider(w http.ResponseWriter, r *http.Request) {
	var in service.ProviderInput
	if !decode(w, r, &in) {
		return
	}
	v, err := a.svc.UpdateProvider(r.Context(), chi.URLParam(r, "id"), in)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, v)
}

func (a *API) deleteLLMProvider(w http.ResponseWriter, r *http.Request) {
	if err := a.svc.DeleteProvider(r.Context(), chi.URLParam(r, "id")); err != nil {
		a.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) createLLMModel(w http.ResponseWriter, r *http.Request) {
	var in service.ModelInput
	if !decode(w, r, &in) {
		return
	}
	v, err := a.svc.CreateModel(r.Context(), in)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, v)
}

func (a *API) updateLLMModel(w http.ResponseWriter, r *http.Request) {
	var in service.ModelInput
	if !decode(w, r, &in) {
		return
	}
	v, err := a.svc.UpdateModel(r.Context(), chi.URLParam(r, "id"), in)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, v)
}

func (a *API) deleteLLMModel(w http.ResponseWriter, r *http.Request) {
	if err := a.svc.DeleteModel(r.Context(), chi.URLParam(r, "id")); err != nil {
		a.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) testLLMModel(w http.ResponseWriter, r *http.Request) {
	res, err := a.svc.TestModel(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (a *API) putLLMRoles(w http.ResponseWriter, r *http.Request) {
	var in map[string]string
	if !decode(w, r, &in) {
		return
	}
	v, err := a.svc.SaveRoles(r.Context(), in)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, v)
}

func (a *API) putLLMLimits(w http.ResponseWriter, r *http.Request) {
	var in service.LLMLimits
	if !decode(w, r, &in) {
		return
	}
	v, err := a.svc.SaveLimits(r.Context(), in)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, v)
}

func (a *API) listCalls(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	page, err := a.svc.ListCalls(r.Context(), service.CallFilter{
		Days: intParam(r, "days", 30), Source: q.Get("source"), Role: q.Get("role"), FailedOnly: q.Get("failed") == "1",
		Limit: intParam(r, "limit", 20), Offset: intParam(r, "offset", 0),
	})
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, page)
}

// uploadAIUsage takes the token counts of AI explanations the app requested from the model itself.
func (a *API) uploadAIUsage(w http.ResponseWriter, r *http.Request) {
	var in []service.UsageIn
	if !decode(w, r, &in) {
		return
	}
	res, err := a.svc.UploadAIUsage(r.Context(), strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "), in)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (a *API) appAIConfig(w http.ResponseWriter, r *http.Request) {
	cfg, err := a.svc.AppAIConfig(r.Context(), strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, cfg)
}

func (a *API) syncNotesDown(w http.ResponseWriter, r *http.Request) {
	page, err := a.svc.SyncNotes(r.Context(), int64(intParam(r, "since", 0)), intParam(r, "limit", 100))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, page)
}

func (a *API) syncNotesUp(w http.ResponseWriter, r *http.Request) {
	var in []service.NoteIn
	if !decode(w, r, &in) {
		return
	}
	res, err := a.svc.UploadNotes(r.Context(), in)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (a *API) uploadMedia(w http.ResponseWriter, r *http.Request) {
	limit := int64(service.MaxMediaBytes) + 1<<20 // headroom for multipart framing
	r.Body = http.MaxBytesReader(w, r.Body, limit)
	if err := r.ParseMultipartForm(limit); err != nil {
		writeError(w, http.StatusRequestEntityTooLarge, "upload too large or malformed")
		return
	}
	file, _, err := r.FormFile("file")
	if err != nil {
		writeError(w, http.StatusBadRequest, `multipart field "file" is required`)
		return
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, int64(service.MaxMediaBytes)+1))
	if err != nil {
		writeError(w, http.StatusBadRequest, "could not read upload")
		return
	}
	v, err := a.svc.PutMedia(r.Context(), data)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, v)
}

func (a *API) getMedia(w http.ResponseWriter, r *http.Request) {
	m, err := a.svc.GetMedia(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	h := w.Header()
	h.Set("Content-Type", m.Mime)
	h.Set("X-Content-Type-Options", "nosniff")
	// Opened directly, an SVG is a document of its own: this keeps it a dead drawing even if the
	// upload checks ever miss something. <img> and the phone apps are unaffected.
	h.Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; sandbox")
	// The id is the content hash, so a given URL never changes.
	h.Set("Cache-Control", "public, max-age=31536000, immutable")
	h.Set("Content-Length", strconv.Itoa(len(m.Data)))
	_, _ = w.Write(m.Data)
}
