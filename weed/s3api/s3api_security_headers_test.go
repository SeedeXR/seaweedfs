package s3api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSetSecurityHeaders(t *testing.T) {
	saved := s3ContentSecurityPolicy
	defer func() { s3ContentSecurityPolicy = saved }()

	s3ContentSecurityPolicy = ""
	w := httptest.NewRecorder()
	setSecurityHeaders(w, httptest.NewRequest(http.MethodGet, "/bucket/key", nil))
	if got := w.Header().Get("Server"); got != "SeaweedFS" {
		t.Errorf("Server = %q; must not carry a version", got)
	}
	if got := w.Header().Get("X-Content-Type-Options"); got != "nosniff" {
		t.Errorf("X-Content-Type-Options = %q", got)
	}
	if got := w.Header().Get("Cross-Origin-Resource-Policy"); got != "cross-origin" {
		t.Errorf("Cross-Origin-Resource-Policy = %q, want cross-origin", got)
	}
	if w.Header().Get("Strict-Transport-Security") != "" {
		t.Error("HSTS must not be sent over plain HTTP")
	}
	if w.Header().Get("Content-Security-Policy") != "" {
		t.Error("CSP must stay off unless configured")
	}

	s3ContentSecurityPolicy = "sandbox; default-src 'none'"
	w = httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodGet, "/bucket/evil.html", nil)
	r.Header.Set("X-Forwarded-Proto", "https")
	setSecurityHeaders(w, r)
	if !strings.HasPrefix(w.Header().Get("Strict-Transport-Security"), "max-age=") {
		t.Error("HSTS missing behind an HTTPS proxy")
	}
	if got := w.Header().Get("Content-Security-Policy"); got != s3ContentSecurityPolicy {
		t.Errorf("CSP = %q, want the configured policy", got)
	}
}
