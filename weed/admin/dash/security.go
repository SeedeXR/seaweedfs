package dash

import (
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/sessions"
	util_http "github.com/seaweedfs/seaweedfs/weed/util/http"
	"golang.org/x/time/rate"
)

// RequestIsHTTPS reports whether the client reached us over HTTPS, directly
// or through a TLS-terminating proxy.
func RequestIsHTTPS(r *http.Request) bool {
	return util_http.RequestIsHTTPS(r)
}

// The admin UI uses inline <script> blocks and on* handlers, so scripts need
// 'unsafe-inline'; everything else is same-origin only. The file browser
// embeds PDF previews from its own download endpoint, so same-origin
// embedding is allowed and cross-origin framing is not.
const adminContentSecurityPolicy = "default-src 'self'; " +
	"script-src 'self' 'unsafe-inline'; " +
	"style-src 'self' 'unsafe-inline'; " +
	"img-src 'self' data: blob:; " +
	"font-src 'self' data:; " +
	"connect-src 'self'; " +
	"object-src 'self'; " +
	"base-uri 'self'; " +
	"form-action 'self'; " +
	"frame-ancestors 'self'"

// SecurityHeaders sets browser hardening headers on every admin response.
func SecurityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", adminContentSecurityPolicy)
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "SAMEORIGIN")
		h.Set("Referrer-Policy", "same-origin")
		h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=()")
		h.Set("Cross-Origin-Opener-Policy", "same-origin")
		h.Set("Cross-Origin-Resource-Policy", "same-origin")
		if RequestIsHTTPS(r) {
			h.Set("Strict-Transport-Security", "max-age=31536000")
		}
		if !strings.Contains(r.URL.Path, "/static/") {
			// Pages and API responses carry session-scoped data.
			h.Set("Cache-Control", "no-store")
		}
		next.ServeHTTP(w, r)
	})
}

// proxyAwareStore marks session cookies Secure whenever the request arrived
// over HTTPS, including through a TLS-terminating proxy. The wrapped store's
// own Options only know whether the admin server itself serves TLS.
type proxyAwareStore struct {
	sessions.Store
}

// NewProxyAwareStore wraps store so cookies it issues on HTTPS requests are Secure.
func NewProxyAwareStore(store sessions.Store) sessions.Store {
	return proxyAwareStore{store}
}

func (s proxyAwareStore) Get(r *http.Request, name string) (*sessions.Session, error) {
	session, err := s.Store.Get(r, name)
	markSecure(r, session)
	return session, err
}

func (s proxyAwareStore) New(r *http.Request, name string) (*sessions.Session, error) {
	session, err := s.Store.New(r, name)
	markSecure(r, session)
	return session, err
}

func markSecure(r *http.Request, session *sessions.Session) {
	if session != nil && session.Options != nil && RequestIsHTTPS(r) {
		session.Options.Secure = true
	}
}

// loginFailureLimiter caps failed logins across all clients: a burst of 10,
// then one every 3s (at most ~1200 guesses an hour). It is global rather
// than per IP because behind a proxy every client shares the proxy's
// address. Under attack a legitimate login may wait a few seconds.
// ponytail: global limiter; per-client buckets keyed on a trusted
// X-Forwarded-For if lockout of real users ever matters.
var loginFailureLimiter = rate.NewLimiter(rate.Every(3*time.Second), 10)

// loginBlocked reports whether recent failures have exhausted the budget.
func loginBlocked() bool {
	return loginFailureLimiter.Tokens() < 1
}

// recordLoginFailure spends one token of the failure budget.
func recordLoginFailure() {
	loginFailureLimiter.Allow()
}

// clientAddress describes the caller for logs: the peer address, plus the
// forwarded chain when a proxy supplied one.
func clientAddress(r *http.Request) string {
	if fwd := r.Header.Get("X-Forwarded-For"); fwd != "" {
		return r.RemoteAddr + " (X-Forwarded-For: " + fwd + ")"
	}
	return r.RemoteAddr
}

// Session revocation. The cookie store is stateless, so without this a
// session cookie copied before logout would stay valid for its whole MaxAge.
// Each login stamps the session with a random id; logout revokes that id
// until the cookie would have expired anyway.
// ponytail: in-memory, so revocations clear on restart (cookies issued
// before then become valid again until MaxAge); persist the set under the
// admin data dir if that window matters.
var revokedSessions = struct {
	sync.Mutex
	until map[string]time.Time
}{until: map[string]time.Time{}}

const sessionIDKey = "sid"

func revokeSession(id string, until time.Time) {
	revokedSessions.Lock()
	defer revokedSessions.Unlock()
	now := time.Now()
	for sid, exp := range revokedSessions.until {
		if now.After(exp) {
			delete(revokedSessions.until, sid)
		}
	}
	revokedSessions.until[id] = until
}

func sessionRevoked(id string) bool {
	revokedSessions.Lock()
	defer revokedSessions.Unlock()
	exp, ok := revokedSessions.until[id]
	return ok && time.Now().Before(exp)
}

// SessionIsAuthenticated reports whether session belongs to a logged-in,
// not logged-out user.
func SessionIsAuthenticated(session *sessions.Session) bool {
	if session == nil {
		return false
	}
	authenticated, _ := session.Values["authenticated"].(bool)
	username, _ := session.Values["username"].(string)
	sid, _ := session.Values[sessionIDKey].(string)
	return authenticated && username != "" && sid != "" && !sessionRevoked(sid)
}
