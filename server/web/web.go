// Package web embeds the built admin UI. `make admin` builds ../admin into
// web/dist; until then a placeholder page explains how.
package web

import (
	"embed"
	"io/fs"
)

//go:embed all:dist
var distFS embed.FS

//go:embed placeholder
var placeholderFS embed.FS

// Dist returns the admin UI files, or a placeholder page when the UI has not
// been built into web/dist yet.
func Dist() fs.FS {
	if f, err := distFS.Open("dist/index.html"); err == nil {
		f.Close()
		return mustSub(distFS, "dist")
	}
	return mustSub(placeholderFS, "placeholder")
}

func mustSub(fsys fs.FS, dir string) fs.FS {
	sub, err := fs.Sub(fsys, dir)
	if err != nil {
		panic(err) // paths are fixed at compile time
	}
	return sub
}
