package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const agentVersion = "0.5.0"

var (
	ErrRevoked = errors.New("agent access revoked")
	ErrExpired = errors.New("pairing code expired")
)

type Report struct {
	Endpoint          string `json:"endpoint"`
	ListenPort        int    `json:"listenPort"`
	PublicKey         string `json:"publicKey"`
	Subnet            string `json:"subnet"`
	InterfaceName     string `json:"interfaceName"`
	InterfaceUp       bool   `json:"interfaceUp"`
	ExternalInterface string `json:"externalInterface"`
	ExistingConfig    bool   `json:"existingConfig"`
}

type Client struct {
	BaseURL      string
	HTTP         *http.Client
	Public       ed25519.PublicKey
	Private      ed25519.PrivateKey
	EnrollmentID string
	Nonce        string
	Token        string
}

func (c *Client) client() *http.Client {
	if c.HTTP != nil {
		return c.HTTP
	}
	return &http.Client{
		Timeout: 10 * time.Second,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) > 0 && req.URL.Host != via[0].URL.Host {
				return errors.New("redirect to another host refused")
			}
			return nil
		},
	}
}

func (c *Client) Enroll(ctx context.Context, code string, report Report) error {
	timestamp := time.Now().Unix()
	public := base64.RawURLEncoding.EncodeToString(c.Public)
	message := fmt.Sprintf("family-vpn/v1 enroll\n%s\n%d", public, timestamp)
	payload := map[string]any{
		"code":      code,
		"publicKey": public,
		"version":   agentVersion,
		"timestamp": timestamp,
		"signature": sign(c.Private, message),
		"report":    report,
	}
	var response struct {
		EnrollmentID string `json:"enrollmentId"`
		Nonce        string `json:"nonce"`
		Error        string `json:"error"`
	}
	status, err := c.post(ctx, "/api/agent/enroll", "", payload, &response)
	if err != nil {
		return err
	}
	if status == http.StatusUnauthorized && strings.Contains(response.Error, "отозван") {
		return ErrRevoked
	}
	if status >= 400 {
		return fmt.Errorf("enroll rejected")
	}
	if response.EnrollmentID == "" || response.Nonce == "" {
		return errors.New("enroll response incomplete")
	}
	c.EnrollmentID = response.EnrollmentID
	c.Nonce = response.Nonce
	return nil
}

func (c *Client) Poll(ctx context.Context) (string, error) {
	timestamp := time.Now().Unix()
	public := base64.RawURLEncoding.EncodeToString(c.Public)
	message := fmt.Sprintf("family-vpn/v1 poll\n%s\n%s\n%d", c.EnrollmentID, c.Nonce, timestamp)
	payload := map[string]any{
		"enrollmentId": c.EnrollmentID,
		"publicKey":    public,
		"nonce":        c.Nonce,
		"timestamp":    timestamp,
		"signature":    sign(c.Private, message),
	}
	var response struct {
		Status string `json:"status"`
		Token  string `json:"token"`
		Error  string `json:"error"`
	}
	status, err := c.post(ctx, "/api/agent/poll", "", payload, &response)
	if err != nil {
		return "", err
	}
	if status == http.StatusUnauthorized && strings.Contains(response.Error, "отозван") {
		return "", ErrRevoked
	}
	if status >= 400 {
		return "", errors.New("poll rejected")
	}
	switch response.Status {
	case "expired":
		return response.Status, ErrExpired
	case "paired":
		if response.Token != "" {
			c.Token = response.Token
		}
		return response.Status, nil
	case "pending":
		return response.Status, nil
	default:
		return "", errors.New("poll response incomplete")
	}
}

func (c *Client) Heartbeat(ctx context.Context, report Report, peers []PeerStat, results []JobResult) ([]Job, error) {
	timestamp := time.Now().Unix()
	nonce := newNonce()
	public := base64.RawURLEncoding.EncodeToString(c.Public)
	message := fmt.Sprintf("family-vpn/v1 heartbeat\n%s\n%d\n%s", public, timestamp, nonce)
	payload := map[string]any{
		"version":    agentVersion,
		"report":     report,
		"peers":      peers,
		"jobResults": results,
		"timestamp":  timestamp,
		"nonce":      nonce,
		"signature":  sign(c.Private, message),
	}
	var response struct {
		Error string `json:"error"`
		Jobs  []Job  `json:"jobs"`
	}
	status, err := c.post(ctx, "/api/agent/heartbeat", c.Token, payload, &response)
	if err != nil {
		return nil, err
	}
	if status == http.StatusUnauthorized {
		return nil, ErrRevoked
	}
	if status >= 400 {
		return nil, errors.New("heartbeat rejected")
	}
	return response.Jobs, nil
}

func (c *Client) HeartbeatRetry(ctx context.Context, report Report, peers []PeerStat, results []JobResult, attempts int) ([]Job, error) {
	var last error
	for attempt := 1; attempt <= attempts; attempt++ {
		jobs, err := c.Heartbeat(ctx, report, peers, results)
		if err == nil || errors.Is(err, ErrRevoked) {
			return jobs, err
		}
		last = err
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(time.Duration(attempt) * 10 * time.Millisecond):
		}
	}
	return nil, last
}

func normalizeBackend(raw string) (string, error) {
	trimmed := strings.TrimRight(strings.TrimSpace(raw), "/")
	parsed, err := url.Parse(trimmed)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" || parsed.User != nil {
		return "", errors.New("backend URL is invalid")
	}
	if parsed.RawQuery != "" || parsed.Fragment != "" || (parsed.Path != "" && parsed.Path != "/") {
		return "", errors.New("backend URL must be an origin without a path")
	}
	if port := parsed.Port(); port != "" {
		number, conv := strconv.Atoi(port)
		if conv != nil || number < 1 || number > 65535 {
			return "", errors.New("backend port is invalid")
		}
	}
	switch parsed.Scheme {
	case "https":
		return parsed.Scheme + "://" + parsed.Host, nil
	case "http":
		if !loopbackHost(parsed.Hostname()) {
			return "", errors.New("plain HTTP is only allowed for 127.0.0.1 or localhost")
		}
		return parsed.Scheme + "://" + parsed.Host, nil
	default:
		return "", errors.New("backend must use https")
	}
}

func loopbackHost(host string) bool {
	switch strings.ToLower(host) {
	case "127.0.0.1", "localhost", "::1":
		return true
	default:
		return false
	}
}

func (c *Client) post(ctx context.Context, path string, token string, payload any, dest any) (int, error) {
	base, err := normalizeBackend(c.BaseURL)
	if err != nil {
		return 0, err
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return 0, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, base+path, bytes.NewReader(body))
	if err != nil {
		return 0, err
	}
	request.Header.Set("Content-Type", "application/json")
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	response, err := c.client().Do(request)
	if err != nil {
		return 0, err
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return response.StatusCode, err
	}
	if len(raw) > 0 && dest != nil {
		if err := json.Unmarshal(raw, dest); err != nil {
			return response.StatusCode, err
		}
	}
	return response.StatusCode, nil
}

func sign(private ed25519.PrivateKey, message string) string {
	return base64.RawURLEncoding.EncodeToString(ed25519.Sign(private, []byte(message)))
}

func newNonce() string {
	raw := make([]byte, 24)
	if _, err := rand.Read(raw); err != nil {
		// Fallback keeps heartbeat possible if the OS RNG briefly fails.
		return fmt.Sprintf("%d", time.Now().UnixNano())
	}
	return base64.RawURLEncoding.EncodeToString(raw)
}
