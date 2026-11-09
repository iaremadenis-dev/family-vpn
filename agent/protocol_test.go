package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestEnrollPollAndHeartbeat(t *testing.T) {
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	polls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/agent/enroll":
			w.Write([]byte(`{"enrollmentId":"enr","nonce":"nonce"}`))
		case "/api/agent/poll":
			polls++
			if polls == 1 {
				w.Write([]byte(`{"status":"pending"}`))
				return
			}
			w.Write([]byte(`{"status":"paired","token":"secret-token"}`))
		case "/api/agent/heartbeat":
			if r.Header.Get("Authorization") != "Bearer secret-token" {
				http.Error(w, `{"error":"no"}`, http.StatusUnauthorized)
				return
			}
			w.Write([]byte(`{"ok":true}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	client := &Client{BaseURL: server.URL, Public: public, Private: private}
	if err := client.Enroll(context.Background(), "AAAAA-BBBBB-CCCCC-DDDDD", sampleReport()); err != nil {
		t.Fatal(err)
	}
	status, err := client.Poll(context.Background())
	if err != nil || status != "pending" {
		t.Fatalf("pending poll: %s %v", status, err)
	}
	status, err = client.Poll(context.Background())
	if err != nil || status != "paired" || client.Token != "secret-token" {
		t.Fatalf("paired poll failed: %s", status)
	}
	if _, err := client.Heartbeat(context.Background(), sampleReport(), nil, nil); err != nil {
		t.Fatal(err)
	}
}

func TestExpiredCodeAndRevokedHeartbeat(t *testing.T) {
	public, private, _ := ed25519.GenerateKey(rand.Reader)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/agent/poll":
			w.Write([]byte(`{"status":"expired"}`))
		case "/api/agent/heartbeat":
			w.WriteHeader(http.StatusUnauthorized)
			w.Write([]byte(`{"error":"Доступ агента отозван."}`))
		}
	}))
	defer server.Close()
	client := &Client{BaseURL: server.URL, Public: public, Private: private, EnrollmentID: "enr", Nonce: "nonce", Token: "old"}
	_, err := client.Poll(context.Background())
	if !errors.Is(err, ErrExpired) {
		t.Fatalf("expected expired, got %v", err)
	}
	_, err = client.HeartbeatRetry(context.Background(), sampleReport(), nil, nil, 3)
	if !errors.Is(err, ErrRevoked) {
		t.Fatalf("expected revoked, got %v", err)
	}
}

func TestHeartbeatReconnectsAfterDrop(t *testing.T) {
	hits := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		if hits == 1 {
			hj, ok := w.(http.Hijacker)
			if !ok {
				t.Fatal("no hijacker")
			}
			conn, _, _ := hj.Hijack()
			conn.Close()
			return
		}
		json.NewEncoder(w).Encode(map[string]bool{"ok": true})
	}))
	defer server.Close()
	public, private, _ := ed25519.GenerateKey(rand.Reader)
	client := &Client{
		BaseURL: server.URL,
		Public:  public,
		Private: private,
		Token:   "token",
		HTTP:    &http.Client{Timeout: time.Second},
	}
	if _, err := client.HeartbeatRetry(context.Background(), sampleReport(), nil, nil, 3); err != nil {
		t.Fatal(err)
	}
	if hits < 2 {
		t.Fatalf("expected a retry, hits=%d", hits)
	}
}

func TestInvalidCodeIsRejected(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte(`{"error":"Код не найден."}`))
	}))
	defer server.Close()
	public, private, _ := ed25519.GenerateKey(rand.Reader)
	client := &Client{BaseURL: server.URL, Public: public, Private: private}
	if err := client.Enroll(context.Background(), "bad", sampleReport()); err == nil {
		t.Fatal("expected invalid code to fail")
	}
}

func TestLoopbackHTTPAndRemoteHTTPS(t *testing.T) {
	got, err := normalizeBackend("http://127.0.0.1:13010")
	if err != nil || got != "http://127.0.0.1:13010" {
		t.Fatalf("tunnel backend: %s %v", got, err)
	}
	got, err = normalizeBackend("http://localhost:3010/")
	if err != nil || got != "http://localhost:3010" {
		t.Fatalf("localhost backend: %s %v", got, err)
	}
	got, err = normalizeBackend("http://[::1]:13010")
	if err != nil || got != "http://[::1]:13010" {
		t.Fatalf("ipv6 loopback: %s %v", got, err)
	}
	got, err = normalizeBackend("https://panel.example.com/")
	if err != nil || got != "https://panel.example.com" {
		t.Fatalf("https backend: %s %v", got, err)
	}
	for _, raw := range []string{
		"http://203.0.113.5",
		"http://203.0.113.5:13010",
		"http://panel.example.com",
		"http://10.77.0.1",
		"http://127.0.0.1.example",
		"ftp://127.0.0.1",
	} {
		if _, err := normalizeBackend(raw); err == nil {
			t.Fatalf("expected %s to be refused", raw)
		}
	}
}

func TestRemoteHTTPDoesNotDial(t *testing.T) {
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	client := &Client{BaseURL: "http://203.0.113.5:13010", Public: public, Private: private}
	err = client.Enroll(context.Background(), "AAAAA-BBBBB-CCCCC-DDDDD", sampleReport())
	if err == nil || !strings.Contains(err.Error(), "plain HTTP") {
		t.Fatalf("remote http was not refused: %v", err)
	}
}

func TestEnrollPollAndHeartbeatOnTunnelAddress(t *testing.T) {
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.Host, "127.0.0.1:") {
			t.Errorf("expected loopback host, got %s", r.Host)
		}
		switch r.URL.Path {
		case "/api/agent/enroll":
			w.Write([]byte(`{"enrollmentId":"enr","nonce":"nonce"}`))
		case "/api/agent/poll":
			w.Write([]byte(`{"status":"paired","token":"secret-token"}`))
		case "/api/agent/heartbeat":
			if r.Header.Get("Authorization") != "Bearer secret-token" {
				http.Error(w, `{"error":"no"}`, http.StatusUnauthorized)
				return
			}
			w.Write([]byte(`{"ok":true}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	if _, err := normalizeBackend(server.URL); err != nil {
		t.Fatal(err)
	}
	client := &Client{BaseURL: server.URL, Public: public, Private: private}
	if err := client.Enroll(context.Background(), "AAAAA-BBBBB-CCCCC-DDDDD", sampleReport()); err != nil {
		t.Fatal(err)
	}
	status, err := client.Poll(context.Background())
	if err != nil || status != "paired" || client.Token != "secret-token" {
		t.Fatalf("paired poll failed: %s %v", status, err)
	}
	if _, err := client.Heartbeat(context.Background(), sampleReport(), nil, nil); err != nil {
		t.Fatal(err)
	}
}

func sampleReport() Report {
	return Report{
		Endpoint:          "203.0.113.10",
		ListenPort:        51820,
		PublicKey:         "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
		Subnet:            "10.200.0.0/24",
		InterfaceName:     "wg0",
		InterfaceUp:       true,
		ExternalInterface: "eth0",
	}
}
