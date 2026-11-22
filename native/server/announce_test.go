package main

import (
	"fmt"
	"net"
	"strings"
	"testing"
	"time"
)

// dialOnWrite connects to addr the moment the announcement is written and
// records whether the port already took the connection.
type dialOnWrite struct {
	addr     string
	lines    []string
	accepted []bool
}

func (d *dialOnWrite) Write(p []byte) (int, error) {
	conn, err := net.DialTimeout("tcp", d.addr, time.Second)
	if err == nil {
		_ = conn.Close()
	}
	d.lines = append(d.lines, string(p))
	d.accepted = append(d.accepted, err == nil)
	return len(p), nil
}

func freePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := l.Addr().(*net.TCPAddr).Port
	_ = l.Close()
	return port
}

// The runner polls /health as soon as it reads "Running on": the port must
// already be bound then, or the first poll is refused (~2 s on Windows).
func TestListenAndAnnounceBindsBeforeTheLine(t *testing.T) {
	port := freePort(t)
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	out := &dialOnWrite{addr: addr}
	listener, err := listenAndAnnounce(addr, port, out)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	if len(out.lines) == 0 || !strings.HasPrefix(out.lines[0], fmt.Sprintf("Running on http://localhost:%d\n", port)) {
		t.Fatalf("first line %q, want the runner's Running on line", out.lines)
	}
	for i, ok := range out.accepted {
		if !ok {
			t.Fatalf("line %q was written before the port took connections", out.lines[i])
		}
	}
}

// A port that is taken fails before anything is announced.
func TestListenAndAnnounceTakenPortSaysNothing(t *testing.T) {
	busy, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer busy.Close()
	port := busy.Addr().(*net.TCPAddr).Port
	out := &dialOnWrite{addr: busy.Addr().String()}
	if l, err := listenAndAnnounce(busy.Addr().String(), port, out); err == nil {
		_ = l.Close()
		t.Fatal("bound a port that is taken")
	}
	if len(out.lines) != 0 {
		t.Fatalf("announced %q on a port it could not bind", out.lines)
	}
}
