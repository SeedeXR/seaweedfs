package dash

import (
	"crypto/tls"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/sessions"
	"golang.org/x/time/rate"
)

func TestRequestIsHTTPS(t *testing.T) {
	for _, tc := range []struct {
		name  string
		tls   bool
		proto string
		want  bool
	}{
		{"plain", false, "", false},
		{"direct tls", true, "", true},
		{"proxy https", false, "https", true},
		{"proxy https upper", false, "HTTPS", true},
		{"proxy chain", false, "https, http", true},
		{"proxy http", false, "http", false},
	} {
		r := httptest.NewRequest(http.MethodGet, "/", nil)
		if tc.tls {
			r.TLS = &tls.ConnectionState{}
		}
		if tc.proto != "" {
			r.Header.Set("X-Forwarded-Proto", tc.proto)
		}
		if got := RequestIsHTTPS(r); got != tc.want {
			t.Errorf("%s: RequestIsHTTPS = %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestSecurityHeaders(t *testing.T) {
	handler := SecurityHeaders(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))

	page := httptest.NewRecorder()
	handler.ServeHTTP(page, httptest.NewRequest(http.MethodGet, "/admin", nil))
	for header, want := range map[string]string{
		"X-Content-Type-Options":       "nosniff",
		"X-Frame-Options":              "SAMEORIGIN",
		"Referrer-Policy":              "same-origin",
		"Cache-Control":                "no-store",
		"Cross-Origin-Resource-Policy": "same-origin",
	} {
		if got := page.Header().Get(header); got != want {
			t.Errorf("%s = %q, want %q", header, got, want)
		}
	}
	csp := page.Header().Get("Content-Security-Policy")
	for _, directive := range []string{"frame-ancestors 'self'", "object-src 'self'", "default-src 'self'", "base-uri 'self'"} {
		if !strings.Contains(csp, directive) {
			t.Errorf("CSP %q lacks %q", csp, directive)
		}
	}
	if hsts := page.Header().Get("Strict-Transport-Security"); hsts != "" {
		t.Errorf("HSTS sent over plain HTTP: %q", hsts)
	}

	secure := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodGet, "/static/css/admin.css", nil)
	r.Header.Set("X-Forwarded-Proto", "https")
	handler.ServeHTTP(secure, r)
	if secure.Header().Get("Strict-Transport-Security") == "" {
		t.Error("HSTS missing behind an HTTPS proxy")
	}
	if cc := secure.Header().Get("Cache-Control"); cc == "no-store" {
		t.Error("static assets must stay cacheable")
	}
}

func TestProxyAwareStoreMarksCookieSecure(t *testing.T) {
	inner := sessions.NewCookieStore([]byte("0123456789abcdef0123456789abcdef"))
	inner.Options = &sessions.Options{Path: "/", HttpOnly: true}
	store := NewProxyAwareStore(inner)

	setCookie := func(proto string) string {
		r := httptest.NewRequest(http.MethodGet, "/", nil)
		if proto != "" {
			r.Header.Set("X-Forwarded-Proto", proto)
		}
		w := httptest.NewRecorder()
		session, err := store.Get(r, sessionName)
		if err != nil {
			t.Fatalf("Get: %v", err)
		}
		session.Values["k"] = "v"
		if err := session.Save(r, w); err != nil {
			t.Fatalf("Save: %v", err)
		}
		return w.Header().Get("Set-Cookie")
	}

	if c := setCookie("https"); !strings.Contains(c, "; Secure") {
		t.Errorf("cookie over HTTPS proxy lacks Secure: %s", c)
	}
	if c := setCookie(""); strings.Contains(c, "; Secure") {
		t.Errorf("cookie over plain HTTP must not be Secure (browser would drop it): %s", c)
	}
	if inner.Options.Secure {
		t.Error("wrapper mutated the shared store options")
	}
}

func TestHandleLoginThrottlesRepeatedFailures(t *testing.T) {
	saved := loginFailureLimiter
	loginFailureLimiter = rate.NewLimiter(rate.Every(time.Hour), 3)
	defer func() { loginFailureLimiter = saved }()

	store := sessions.NewCookieStore([]byte("0123456789abcdef0123456789abcdef"))
	handler := (&AdminServer{}).HandleLogin(store, "admin", "right", "", "")

	// A session carrying a CSRF token, as the login page would issue.
	seed := httptest.NewRecorder()
	seedReq := httptest.NewRequest(http.MethodGet, "/login", nil)
	session, _ := store.Get(seedReq, sessionName)
	session.Values[sessionCSRFTokenKey] = "tok"
	if err := session.Save(seedReq, seed); err != nil {
		t.Fatal(err)
	}
	cookie := seed.Header().Get("Set-Cookie")

	login := func(password string) string {
		form := url.Values{"username": {"admin"}, "password": {password}, "csrf_token": {"tok"}}
		r := httptest.NewRequest(http.MethodPost, "/login", strings.NewReader(form.Encode()))
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		r.Header.Set("Cookie", cookie)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w.Header().Get("Location")
	}

	if loc := login("right"); loc != "/admin" {
		t.Fatalf("correct password before any failure: redirect %q, want /admin", loc)
	}
	for i := 0; i < 3; i++ {
		if loc := login("wrong"); !strings.Contains(loc, "Invalid credentials") {
			t.Fatalf("failure %d: redirect %q, want Invalid credentials", i+1, loc)
		}
	}
	if loc := login("right"); !strings.Contains(loc, "Too many failed attempts") {
		t.Fatalf("after exhausting the budget even a correct password must wait: redirect %q", loc)
	}
}

func TestLogoutRevokesSessionCookie(t *testing.T) {
	store := sessions.NewCookieStore([]byte("0123456789abcdef0123456789abcdef"))
	store.Options = &sessions.Options{Path: "/", MaxAge: 3600, HttpOnly: true}
	server := &AdminServer{}
	loginHandler := server.HandleLogin(store, "admin", "right", "", "")
	protected := RequireAuth(store)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	seed := httptest.NewRecorder()
	seedReq := httptest.NewRequest(http.MethodGet, "/login", nil)
	session, _ := store.Get(seedReq, sessionName)
	session.Values[sessionCSRFTokenKey] = "tok"
	if err := session.Save(seedReq, seed); err != nil {
		t.Fatal(err)
	}

	form := url.Values{"username": {"admin"}, "password": {"right"}, "csrf_token": {"tok"}}
	loginReq := httptest.NewRequest(http.MethodPost, "/login", strings.NewReader(form.Encode()))
	loginReq.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	loginReq.Header.Set("Cookie", seed.Header().Get("Set-Cookie"))
	loginResp := httptest.NewRecorder()
	loginHandler.ServeHTTP(loginResp, loginReq)
	sessionCookie := loginResp.Header().Get("Set-Cookie")
	if sessionCookie == "" {
		t.Fatal("login issued no session cookie")
	}

	get := func() int {
		r := httptest.NewRequest(http.MethodGet, "/admin", nil)
		r.Header.Set("Cookie", sessionCookie)
		w := httptest.NewRecorder()
		protected.ServeHTTP(w, r)
		return w.Code
	}
	if code := get(); code != http.StatusOK {
		t.Fatalf("fresh session rejected: %d", code)
	}

	logoutReq := httptest.NewRequest(http.MethodGet, "/logout", nil)
	logoutReq.Header.Set("Cookie", sessionCookie)
	server.HandleLogout(store, httptest.NewRecorder(), logoutReq)

	if code := get(); code != http.StatusTemporaryRedirect {
		t.Fatalf("cookie replayed after logout got %d, want redirect to login", code)
	}
}
