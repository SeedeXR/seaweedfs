package security

import (
	"net"
	"testing"
)

// TestIsWhiteListedPeerTrustsUnixSockets guards the regression where
// `weed mini -whiteList=127.0.0.1` rejected its own volume allocation: the
// master reaches the volume server over a local Unix socket whose peer
// address is "@", which matched no whitelisted IP.
func TestIsWhiteListedPeerTrustsUnixSockets(t *testing.T) {
	g := NewGuard([]string{"127.0.0.1"}, "", 0, "", 0)
	cases := []struct {
		name string
		addr net.Addr
		want bool
	}{
		{"unnamed unix peer", &net.UnixAddr{Name: "@", Net: "unix"}, true},
		{"named unix peer", &net.UnixAddr{Name: "/tmp/seaweedfs-volume-grpc-19340.sock", Net: "unix"}, true},
		{"whitelisted tcp", &net.TCPAddr{IP: net.ParseIP("127.0.0.1"), Port: 5000}, true},
		{"foreign tcp", &net.TCPAddr{IP: net.ParseIP("172.18.0.5"), Port: 5000}, false},
		{"foreign ipv6 tcp", &net.TCPAddr{IP: net.ParseIP("fd00::5"), Port: 5000}, false},
	}
	for _, tc := range cases {
		if got, host := g.IsWhiteListedPeer(tc.addr); got != tc.want {
			t.Errorf("%s: IsWhiteListedPeer(%v) = %v (host %q), want %v", tc.name, tc.addr, got, host, tc.want)
		}
	}
}

func TestIsWhiteListedPeerEmptyWhiteListAllowsAll(t *testing.T) {
	g := NewGuard(nil, "", 0, "", 0)
	if ok, _ := g.IsWhiteListedPeer(&net.TCPAddr{IP: net.ParseIP("203.0.113.9")}); !ok {
		t.Error("no whitelist configured must keep allowing every peer")
	}
}
