package s3api

import (
	"net/http"

	util_http "github.com/seaweedfs/seaweedfs/weed/util/http"
)

// s3ContentSecurityPolicy is applied to every S3 response when set, from
// s3.content_security_policy (env WEED_S3_CONTENT_SECURITY_POLICY). Objects
// are user-supplied, so an HTML or SVG object opened directly would otherwise
// run script on the S3 hostname; a "sandbox" policy prevents that while
// leaving <img>, <video>, fetch() and other subresource loads untouched, since
// CSP only governs documents. Empty (the default) keeps upstream behaviour,
// because sites hosted from a bucket need scripts. Set once at server start.
var s3ContentSecurityPolicy string

// setSecurityHeaders hardens every S3 response. The Server header names the
// product but not its version, so scanners cannot match the exact patch level.
func setSecurityHeaders(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Set("Server", "SeaweedFS")
	h.Set("X-Content-Type-Options", "nosniff")
	// Objects are meant to be embedded by other sites (images, video, models),
	// including pages that opt into cross-origin isolation.
	h.Set("Cross-Origin-Resource-Policy", "cross-origin")
	if util_http.RequestIsHTTPS(r) {
		h.Set("Strict-Transport-Security", "max-age=31536000")
	}
	if s3ContentSecurityPolicy != "" {
		h.Set("Content-Security-Policy", s3ContentSecurityPolicy)
	}
}
