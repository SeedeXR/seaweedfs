package handlers

import "testing"

// Inline downloads render in the admin origin, so anything that can carry
// script (SVG, HTML) must be an attachment or an uploaded file becomes stored
// XSS against the admin session.
func TestInlinePreviewAllowed(t *testing.T) {
	for contentType, want := range map[string]bool{
		"image/png":                true,
		"image/jpeg":               true,
		"image/webp":               true,
		"application/pdf":          true,
		"image/svg+xml":            false,
		"text/html":                false,
		"application/xhtml+xml":    false,
		"text/plain":               false,
		"application/octet-stream": false,
	} {
		if got := inlinePreviewAllowed(contentType); got != want {
			t.Errorf("inlinePreviewAllowed(%q) = %v, want %v", contentType, got, want)
		}
	}
}
