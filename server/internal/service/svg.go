package service

import (
	"bytes"
	"encoding/xml"
	"errors"
	"io"
	"math"
	"regexp"
	"strconv"
	"strings"
)

// MaxSVGBytes caps one SVG diagram. Hand-drawn UML diagrams are a few KB; anything bigger is suspect.
const MaxSVGBytes = 1 << 20

const svgNamespace = "http://www.w3.org/2000/svg"

// svgElements is every element a diagram may use. It is a whitelist on purpose: <script>, <style>
// (CSS can import), <foreignObject>, <image>, <a>, <animate*>, <iframe> and friends are all refused,
// so an uploaded SVG is a static drawing and nothing else.
var svgElements = map[string]bool{
	"svg": true, "g": true, "defs": true, "title": true, "desc": true,
	"rect": true, "circle": true, "ellipse": true, "line": true, "polyline": true, "polygon": true, "path": true,
	"text": true, "tspan": true, "marker": true, "clipPath": true,
	"linearGradient": true, "radialGradient": true, "stop": true, "use": true,
}

var (
	// url(#id) is the only reference form an attribute may contain.
	svgURLRef   = regexp.MustCompile(`(?i)url\(\s*['"]?([^)'"]*)['"]?\s*\)`)
	svgLength   = regexp.MustCompile(`^\s*([0-9]*\.?[0-9]+)\s*(px)?\s*$`)
	svgOpenTail = regexp.MustCompile(`(?s)\A\s*(?:\xEF\xBB\xBF)?\s*(?:<\?xml[^>]*\?>\s*)?(?:<!--.*?-->\s*)*<svg[\s>]`)
)

// looksLikeSVG reports whether data starts like an SVG document (an optional XML declaration and
// comments, then <svg>). Other XML or text is not an SVG and falls through to the raster checks.
func looksLikeSVG(data []byte) bool {
	head := data
	if len(head) > 4096 {
		head = head[:4096]
	}
	return svgOpenTail.Match(head)
}

// checkSVG verifies that data is a well-formed, static SVG and returns its size in CSS pixels
// (from width/height, else the viewBox; 0 when neither is given).
//
// Images are shown through <img> and the phone apps' SVG renderer, which never run script, but the
// bytes are also served from a URL that can be opened directly, so anything active is refused here.
func checkSVG(data []byte) (width, height int64, err error) {
	if len(data) > MaxSVGBytes {
		return 0, 0, invalid("SVG larger than %d bytes", MaxSVGBytes)
	}
	dec := xml.NewDecoder(bytes.NewReader(data))
	dec.Strict = true
	depth := 0
	seenRoot := false
	for {
		tok, err := dec.Token()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return 0, 0, invalid("not a valid SVG: %v", err)
		}
		switch t := tok.(type) {
		case xml.Directive:
			// <!DOCTYPE> and <!ENTITY> enable entity-expansion tricks; a drawing never needs them.
			return 0, 0, invalid("SVG may not contain a DOCTYPE or ENTITY declaration")
		case xml.ProcInst:
			if t.Target != "xml" {
				return 0, 0, invalid("SVG may not contain processing instruction <?%s?>", t.Target)
			}
		case xml.StartElement:
			depth++
			if depth > 64 {
				return 0, 0, invalid("SVG is nested too deeply")
			}
			name := t.Name.Local
			if t.Name.Space != "" && t.Name.Space != svgNamespace {
				return 0, 0, invalid("SVG element <%s> is in a foreign namespace", name)
			}
			if !svgElements[name] {
				return 0, 0, invalid("SVG element <%s> is not allowed", name)
			}
			if !seenRoot {
				seenRoot = true
				if name != "svg" || t.Name.Space != svgNamespace {
					return 0, 0, invalid(`the SVG root must be <svg xmlns="%s">`, svgNamespace)
				}
				width, height = svgSize(t.Attr)
			}
			if err := checkSVGAttrs(name, t.Attr); err != nil {
				return 0, 0, err
			}
		case xml.EndElement:
			depth--
		}
	}
	if !seenRoot {
		return 0, 0, invalid("not a valid SVG: no <svg> element")
	}
	return width, height, nil
}

func checkSVGAttrs(elem string, attrs []xml.Attr) error {
	for _, a := range attrs {
		name := strings.ToLower(a.Name.Local)
		val := strings.TrimSpace(a.Value)
		switch {
		case a.Name.Space == "xmlns" || name == "xmlns":
			continue // namespace declarations; the root's was checked by the decoder
		case strings.HasPrefix(name, "on"):
			return invalid("SVG attribute %q (an event handler) is not allowed", a.Name.Local)
		case name == "href":
			if !strings.HasPrefix(val, "#") {
				return invalid("SVG <%s> href must point inside the drawing (#id), got %q", elem, val)
			}
			continue
		}
		low := strings.ToLower(val)
		if strings.Contains(low, "javascript:") || strings.Contains(low, "data:") || strings.Contains(low, "<script") {
			return invalid("SVG attribute %q holds active content", a.Name.Local)
		}
		for _, m := range svgURLRef.FindAllStringSubmatch(val, -1) {
			if !strings.HasPrefix(strings.TrimSpace(m[1]), "#") {
				return invalid("SVG attribute %q references something outside the drawing", a.Name.Local)
			}
		}
		if strings.Contains(low, "@import") {
			return invalid("SVG attribute %q holds an import", a.Name.Local)
		}
	}
	return nil
}

// svgSize reads the drawing's size from width/height, falling back to the viewBox.
func svgSize(attrs []xml.Attr) (int64, int64) {
	var w, h float64
	var vb []float64
	for _, a := range attrs {
		switch a.Name.Local {
		case "width":
			w = svgPixels(a.Value)
		case "height":
			h = svgPixels(a.Value)
		case "viewBox":
			for _, f := range strings.FieldsFunc(a.Value, func(r rune) bool { return r == ',' || r == ' ' || r == '\t' || r == '\n' }) {
				v, err := strconv.ParseFloat(f, 64)
				if err != nil {
					vb = nil
					break
				}
				vb = append(vb, v)
			}
		}
	}
	if (w <= 0 || h <= 0) && len(vb) == 4 {
		if w <= 0 {
			w = vb[2]
		}
		if h <= 0 {
			h = vb[3]
		}
	}
	if math.IsNaN(w) || math.IsNaN(h) || w < 0 || h < 0 {
		return 0, 0
	}
	return int64(w), int64(h)
}

// svgPixels parses "480" or "480px"; percentages and other units give 0 (unknown).
func svgPixels(s string) float64 {
	m := svgLength.FindStringSubmatch(s)
	if m == nil {
		return 0
	}
	v, _ := strconv.ParseFloat(m[1], 64)
	return v
}
