package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
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
	if err := client.Heartbeat(context.Background(), sampleReport()); err != nil {
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
	err = client.HeartbeatRetry(context.Background(), sampleReport(), 3)
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
	if err := client.HeartbeatRetry(context.Background(), sampleReport(), 3); err != nil {
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
