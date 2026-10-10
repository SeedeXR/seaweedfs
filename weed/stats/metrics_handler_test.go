package stats

import (
	"net/http"
	"net/http/httptest"
	_ "net/http/pprof" // registers /debug/pprof on http.DefaultServeMux
	"testing"
)

func TestMetricsHandlerDoesNotExposePprof(t *testing.T) {
	srv := httptest.NewServer(metricsHandler())
	defer srv.Close()

	for path, want := range map[string]int{
		"/metrics":                       http.StatusOK,
		"/debug/pprof/":                  http.StatusNotFound,
		"/debug/pprof/heap":              http.StatusNotFound,
		"/debug/pprof/goroutine?debug=2": http.StatusNotFound,
	} {
		resp, err := http.Get(srv.URL + path)
		if err != nil {
			t.Fatalf("GET %s: %v", path, err)
		}
		resp.Body.Close()
		if resp.StatusCode != want {
			t.Errorf("GET %s = %d, want %d", path, resp.StatusCode, want)
		}
	}
}
