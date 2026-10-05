// Package httpapi exposes the admin REST API, the SSE progress stream and the
// embedded admin UI.
package httpapi

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io/fs"
	"log/slog"
	"net/http"
	"path"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"github.com/chlu-ux/quizmind/server/internal/events"
	"github.com/chlu-ux/quizmind/server/internal/service"
)

type API struct {
	svc    *service.Service
	hub    *events.Hub
	token  string // guards /admin only; empty: no auth (only allowed when listening on loopback)
	log    *slog.Logger
	static fs.FS
}

func New(svc *service.Service, hub *events.Hub, token string, static fs.FS, log *slog.Logger) http.Handler {
	a := &API{svc: svc, hub: hub, token: token, static: static, log: log}
	r := chi.NewRouter()
	r.Use(middleware.Recoverer, a.logRequests)

	r.Get("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})

	r.Route("/admin", func(r chi.Router) {
		r.Use(a.auth)
		r.Get("/banks", a.listBanks)
		r.Post("/banks", a.createBank)

		r.Get("/documents", a.listDocuments)
		r.Post("/documents", a.uploadDocument)
		r.Get("/documents/{id}", a.getDocument)
		r.Get("/documents/{id}/content", a.getDocumentContent)
		r.Post("/documents/{id}/retry", a.retryDocument)

		r.Get("/jobs", a.listJobs)
		r.Post("/jobs/{id}/retry", a.retryJob)
		r.Get("/events", a.streamEvents)

		r.Get("/questions", a.listQuestions)
		r.Post("/questions/bulk", a.bulkReview)
		r.Get("/questions/{id}", a.getQuestion)
		r.Patch("/questions/{id}", a.editQuestion)
		r.Post("/questions/{id}/approve", a.approveQuestion)
		r.Post("/questions/{id}/reject", a.rejectQuestion)
		r.Post("/questions/{id}/dismiss-flags", a.dismissFlags)

		r.Post("/media", a.uploadMedia)

		r.Get("/usage", a.usage)

		r.Get("/ai", a.getAIConfig)
		r.Put("/ai", a.putAIConfig)
		r.Post("/ai/test", a.testAIConfig)
		r.Get("/ai/notes", a.listAINotes)
	})

	// The quiz client API is deliberately unauthenticated: practising needs no token.
	r.Route("/api/v1", func(r chi.Router) {
		r.Get("/banks", a.appBanks)
		// Pictures used by questions. Unauthenticated like the rest of practising; the ids are
		// content hashes, and the answer to a question is never inside a picture's URL.
		r.Get("/media/{id}", a.getMedia)
		r.Get("/sync/questions", a.syncQuestions)
		r.Get("/sync/states", a.syncStatesDown)
		r.Get("/sync/attempts", a.syncAttemptsDown)
		r.Post("/sync/attempts", a.syncAttemptsUp)
		r.Get("/sync/exams", a.syncExamsDown)
		r.Post("/sync/exams", a.syncExamsUp)
		r.Post("/sync/states", a.syncStatesUp)
		r.Get("/sync/sessions", a.syncSessionsDown)
		r.Post("/sync/sessions", a.syncSessionsUp)
		r.Get("/sync/notes", a.syncNotesDown)
		r.Post("/sync/notes", a.syncNotesUp)
		r.Post("/questions/{id}/flag", a.flagQuestion)
		// Unlike the rest, this one hands out the LLM API key, so it needs the app access token.
		r.Get("/ai/config", a.appAIConfig)
	})

	r.NotFound(a.serveUI)
	return r
}

// ---- middleware ----

func (a *API) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if a.token == "" {
			next.ServeHTTP(w, r)
			return
		}
		got := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		// EventSource cannot set headers, so the SSE endpoint also accepts a query token.
		if got == "" && r.URL.Path == "/admin/events" {
			got = r.URL.Query().Get("access_token")
		}
		if subtle.ConstantTimeCompare([]byte(got), []byte(a.token)) != 1 {
			writeError(w, http.StatusUnauthorized, "missing or invalid token")
			return
		}
		next.ServeHTTP(w, r)
	})
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) { w.status = code; w.ResponseWriter.WriteHeader(code) }

// Flush keeps SSE working through the wrapper.
func (w *statusWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (a *API) logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(sw, r)
		// Log the path only: the SSE query string may carry the token.
		a.log.Info("http", "method", r.Method, "path", r.URL.Path, "status", sw.status, "ms", time.Since(start).Milliseconds())
	})
}

// ---- helpers ----

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// fail maps service errors to HTTP statuses. Unexpected errors are logged and
// reported generically so internals do not leak.
func (a *API) fail(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, service.ErrNotFound):
		writeError(w, http.StatusNotFound, err.Error())
	case errors.Is(err, service.ErrUnauthorized):
		writeError(w, http.StatusUnauthorized, "missing or invalid access token")
	case errors.Is(err, service.ErrInvalid):
		writeError(w, http.StatusBadRequest, strings.TrimPrefix(err.Error(), service.ErrInvalid.Error()+": "))
	default:
		a.log.Error("request failed", "method", r.Method, "path", r.URL.Path, "err", err)
		writeError(w, http.StatusInternalServerError, "internal error")
	}
}

func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	if err := json.NewDecoder(r.Body).Decode(v); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return false
	}
	return true
}

func intParam(r *http.Request, name string, def int) int {
	if v, err := strconv.Atoi(r.URL.Query().Get(name)); err == nil {
		return v
	}
	return def
}

// ---- static admin UI ----

func (a *API) serveUI(w http.ResponseWriter, r *http.Request) {
	if strings.HasPrefix(r.URL.Path, "/admin/") || strings.HasPrefix(r.URL.Path, "/api/") {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	// The phone app lives under /m/ inside the same embedded tree (built by `make h5`).
	if r.URL.Path == "/m" {
		http.Redirect(w, r, "/m/", http.StatusMovedPermanently)
		return
	}
	p := strings.TrimPrefix(path.Clean(r.URL.Path), "/")
	if p == "" {
		p = "index.html"
	}
	fallback := "index.html"
	if p == "m" || strings.HasPrefix(p, "m/") {
		fallback = "m/index.html"
		if _, err := fs.Stat(a.static, fallback); err != nil {
			writeError(w, http.StatusNotFound, "phone app not built (run: make h5)")
			return
		}
	}
	if f, err := a.static.Open(p); err == nil {
		st, serr := f.Stat()
		f.Close()
		if serr == nil && !st.IsDir() {
			http.ServeFileFS(w, r, a.static, p)
			return
		}
	}
	// Single-page app: unknown paths fall back to the entry point.
	http.ServeFileFS(w, r, a.static, fallback)
}

func jsonMarshal(v any) ([]byte, error) { return json.Marshal(v) }
