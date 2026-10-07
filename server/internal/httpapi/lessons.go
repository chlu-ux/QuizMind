package httpapi

import "net/http"

// lessons serves the reading library. ?version=<n> is the version the app already holds: if it
// is still current the answer carries no sections.
func (a *API) lessons(w http.ResponseWriter, r *http.Request) {
	page, err := a.svc.Lessons(r.Context(), int64(intParam(r, "version", 0)))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, page)
}
