package http

import (
	"net/http"
	"strings"
)

// RequestIsHTTPS reports whether the client reached us over HTTPS, either
// directly or through a TLS-terminating proxy such as Traefik. Trusting
// X-Forwarded-Proto here is safe as long as the answer only tightens what a
// response asks of the client's own browser (Secure cookies, HSTS).
func RequestIsHTTPS(r *http.Request) bool {
	if r.TLS != nil {
		return true
	}
	proto, _, _ := strings.Cut(r.Header.Get("X-Forwarded-Proto"), ",")
	return strings.EqualFold(strings.TrimSpace(proto), "https")
}
