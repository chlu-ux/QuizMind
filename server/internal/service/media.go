package service

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"fmt"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/chlu-ux/quizmind/server/internal/store"
)

// MaxMediaBytes caps one uploaded raster picture. Diagrams are small; this is generous. SVG has its own,
// lower cap (MaxSVGBytes).
const MaxMediaBytes = 5 << 20

// mediaIDLen is how many hex digits of the content hash make up a media id. The
// mediaRef pattern below must match it.
const mediaIDLen = 24

// MediaRefPrefix starts a reference inside Markdown: `![alt](media:<id>)`.
const MediaRefPrefix = "media:"

var mediaRef = regexp.MustCompile(`media:([0-9a-f]{24})`)

// SVGMime is the type of a stored SVG diagram.
const SVGMime = "image/svg+xml"

// allowedMedia lists the raster types an upload may be. SVG is accepted too, but only after checkSVG
// has proved it is a static drawing (no script, no external references).
var allowedMedia = map[string]bool{"image/png": true, "image/jpeg": true, "image/gif": true, "image/webp": true}

type MediaView struct {
	ID     string `json:"id"`
	Ref    string `json:"ref"` // what to put in Markdown: media:<id>
	Mime   string `json:"mime"`
	Size   int64  `json:"size"`
	Width  int64  `json:"width"`
	Height int64  `json:"height"`
}

func mediaView(id, mime string, size, w, h int64) MediaView {
	return MediaView{ID: id, Ref: MediaRefPrefix + id, Mime: mime, Size: size, Width: w, Height: h}
}

// PutMedia stores a picture and returns its reference. Uploading the same bytes again
// returns the same id. The type comes from the content, never from the file name.
func (s *Service) PutMedia(ctx context.Context, data []byte) (MediaView, error) {
	if len(data) == 0 {
		return MediaView{}, invalid("empty file")
	}
	if len(data) > MaxMediaBytes {
		return MediaView{}, invalid("image larger than %d bytes", MaxMediaBytes)
	}
	var mime string
	var w, h int64
	if looksLikeSVG(data) {
		var err error
		if w, h, err = checkSVG(data); err != nil {
			return MediaView{}, err
		}
		mime = SVGMime
	} else {
		mime = http.DetectContentType(data)
		if !allowedMedia[mime] {
			return MediaView{}, invalid("only SVG, PNG, JPEG, GIF or WebP images are accepted")
		}
		if cfg, _, err := image.DecodeConfig(bytes.NewReader(data)); err == nil {
			w, h = int64(cfg.Width), int64(cfg.Height)
		} else if mime != "image/webp" { // WebP has no decoder in the standard library
			return MediaView{}, invalid("not a valid image")
		}
	}
	sum := sha256.Sum256(data)
	id := hex.EncodeToString(sum[:])[:mediaIDLen]
	err := store.New(s.DB.Write).InsertMedia(ctx, store.InsertMediaParams{
		ID: id, Mime: mime, Size: int64(len(data)), Width: w, Height: h, Data: data, CreatedAt: nowMs(),
	})
	if err != nil {
		return MediaView{}, err
	}
	return mediaView(id, mime, int64(len(data)), w, h), nil
}

// GetMedia returns a stored picture.
func (s *Service) GetMedia(ctx context.Context, id string) (store.Medium, error) {
	m, err := s.reader().GetMedia(ctx, id)
	if err != nil {
		return m, notFound(err, "image")
	}
	return m, nil
}

// MediaRefs lists the distinct media ids referenced from the given Markdown texts.
func MediaRefs(texts ...string) []string {
	seen := map[string]bool{}
	var out []string
	for _, t := range texts {
		for _, m := range mediaRef.FindAllStringSubmatch(t, -1) {
			if !seen[m[1]] {
				seen[m[1]] = true
				out = append(out, m[1])
			}
		}
	}
	return out
}

// checkMedia fails when a text points at a picture that was never uploaded, so a typo
// cannot reach the phones as a broken image.
func checkMedia(ctx context.Context, q *store.Queries, texts ...string) error {
	ids := MediaRefs(texts...)
	if len(ids) == 0 {
		return nil
	}
	have, err := q.ListMediaIDs(ctx, ids)
	if err != nil && err != sql.ErrNoRows {
		return err
	}
	known := map[string]bool{}
	for _, id := range have {
		known[id] = true
	}
	for _, id := range ids {
		if !known[id] {
			return invalid("image %s%s has not been uploaded", MediaRefPrefix, id)
		}
	}
	return nil
}

var markdownImage = regexp.MustCompile(`(!\[[^\]]*\]\()([^)\s]+)(\))`)

// ImportLocalImages uploads every picture that text refers to by a relative file path
// (`![](img/uml.png)`) and rewrites the reference to `media:<id>`. Web addresses and references
// that already are media: are left alone. Paths are looked up under root and cannot leave it.
// For material written offline: lecture notes and hand-written question files.
func (s *Service) ImportLocalImages(ctx context.Context, text, root string) (string, error) {
	var firstErr error
	out := markdownImage.ReplaceAllStringFunc(text, func(m string) string {
		if firstErr != nil {
			return m
		}
		parts := markdownImage.FindStringSubmatch(m)
		src := parts[2]
		if strings.Contains(src, ":") || strings.HasPrefix(src, "/") { // URL, media:, data:, absolute path
			return m
		}
		path := filepath.Join(root, filepath.FromSlash(src))
		if rel, err := filepath.Rel(root, path); err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			firstErr = invalid("image %q is outside %s", src, root)
			return m
		}
		data, err := os.ReadFile(path)
		if err != nil {
			firstErr = invalid("image %q: %v", src, err)
			return m
		}
		v, err := s.PutMedia(ctx, data)
		if err != nil {
			firstErr = fmt.Errorf("image %q: %w", src, err)
			return m
		}
		return parts[1] + v.Ref + parts[3]
	})
	return out, firstErr
}
