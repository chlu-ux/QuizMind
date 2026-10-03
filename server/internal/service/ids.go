package service

import "github.com/chlu-ux/quizmind/server/internal/ids"

func newID() string { return ids.New() }
