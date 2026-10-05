package service_test

import (
	"bytes"
	"context"
	"image"
	"image/png"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/chlu-ux/quizmind/server/internal/service"
)

func pngBytes(t *testing.T, w, h int) []byte {
	t.Helper()
	var b bytes.Buffer
	require.NoError(t, png.Encode(&b, image.NewRGBA(image.Rect(0, 0, w, h))))
	return b.Bytes()
}

func TestImportLocalImages(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	root := t.TempDir()
	require.NoError(t, os.MkdirAll(filepath.Join(root, "uml"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(root, "uml", "class.png"), pngBytes(t, 20, 10), 0o644))

	text := "看图 ![类图](uml/class.png) 与 ![网图](https://x.test/a.png) 与 ![](media:0123456789abcdef01234567)"
	got, err := e.svc.ImportLocalImages(ctx, text, root)
	require.NoError(t, err)

	refs := service.MediaRefs(got)
	require.Len(t, refs, 2, "the local file was uploaded; the others are untouched")
	assert.Contains(t, got, "![网图](https://x.test/a.png)")
	assert.Contains(t, got, "![](media:0123456789abcdef01234567)")
	assert.NotContains(t, got, "uml/class.png")
	m, err := e.svc.GetMedia(ctx, refs[0])
	require.NoError(t, err)
	assert.Equal(t, "image/png", m.Mime)

	again, err := e.svc.ImportLocalImages(ctx, text, root)
	require.NoError(t, err)
	assert.Equal(t, got, again, "the same file gets the same reference")

	_, err = e.svc.ImportLocalImages(ctx, "![](uml/missing.png)", root)
	assert.ErrorIs(t, err, service.ErrInvalid)
	_, err = e.svc.ImportLocalImages(ctx, "![](../secret.png)", root)
	assert.ErrorContains(t, err, "outside")
	require.NoError(t, os.WriteFile(filepath.Join(root, "notes.png"), []byte("not an image"), 0o644))
	_, err = e.svc.ImportLocalImages(ctx, "![](notes.png)", root)
	assert.Error(t, err, "a file that is not an image is refused")
}
