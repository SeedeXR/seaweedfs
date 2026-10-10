package s3api

import (
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/gorilla/mux"
	"github.com/seaweedfs/seaweedfs/weed/s3api/s3_constants"
	"github.com/seaweedfs/seaweedfs/weed/s3api/s3err"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// A public-read bucket ("anonymous" holding Read:<bucket>) serves objects by
// exact key but must not reveal keys. ListMultipartUploads is routed with
// ACTION_LIST for that reason: under ACTION_READ an anonymous caller could
// list the keys of in-flight uploads and fetch them once they complete.
func TestPublicReadDoesNotGrantListing(t *testing.T) {
	resetMemoryStore()
	defer resetMemoryStore()

	config := `{"identities":[{"name":"anonymous","actions":["Read:media"]}]}`
	f, err := os.CreateTemp("", "s3-config-*.json")
	require.NoError(t, err)
	defer os.Remove(f.Name())
	_, err = f.WriteString(config)
	require.NoError(t, err)
	require.NoError(t, f.Close())

	iam := NewIdentityAccessManagementWithStore(&S3ApiServerOption{Config: f.Name()}, nil, "memory")
	require.True(t, iam.isEnabled())

	for _, tc := range []struct {
		name   string
		object string
		query  string
		action Action
		want   s3err.ErrorCode
	}{
		{"get object by key", "ws/a/b.webp", "", s3_constants.ACTION_READ, s3err.ErrNone},
		{"list objects", "", "list-type=2", s3_constants.ACTION_LIST, s3err.ErrAccessDenied},
		{"list multipart uploads", "", "uploads", s3_constants.ACTION_LIST, s3err.ErrAccessDenied},
		{"list object versions", "", "versions", s3_constants.ACTION_LIST, s3err.ErrAccessDenied},
		{"put object", "ws/a/b.webp", "", s3_constants.ACTION_WRITE, s3err.ErrAccessDenied},
		{"get object in another bucket", "x", "", s3_constants.ACTION_READ, s3err.ErrAccessDenied},
	} {
		t.Run(tc.name, func(t *testing.T) {
			bucket := "media"
			if tc.name == "get object in another bucket" {
				bucket = "private"
			}
			url := "http://localhost:8333/" + bucket
			if tc.object != "" {
				url += "/" + tc.object
			}
			if tc.query != "" {
				url += "?" + tc.query
			}
			r := httptest.NewRequest(http.MethodGet, url, nil)
			if tc.action == s3_constants.ACTION_WRITE {
				r.Method = http.MethodPut
			}
			r = mux.SetURLVars(r, map[string]string{"bucket": bucket, "object": tc.object})
			_, errCode := iam.authRequest(r, tc.action)
			assert.Equal(t, tc.want, errCode)
		})
	}
}
