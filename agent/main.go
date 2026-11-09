package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

type stateFile struct {
	Public       string `json:"publicKey"`
	Private      string `json:"privateKey"`
	EnrollmentID string `json:"enrollmentId,omitempty"`
	Nonce        string `json:"nonce,omitempty"`
	Token        string `json:"token,omitempty"`
	Code         string `json:"pairingCode,omitempty"`
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "enroll":
		os.Exit(runEnroll(os.Args[2:]))
	case "run":
		os.Exit(runLoop(os.Args[2:]))
	case "code":
		os.Exit(printCode(os.Args[2:]))
	default:
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: family-vpn-agent enroll|run|code --backend URL --data DIR")
}

func runEnroll(args []string) int {
	flags := flag.NewFlagSet("enroll", flag.ContinueOnError)
	backend := flags.String("backend", "", "panel base URL")
	data := flags.String("data", "/var/lib/family-vpn", "state directory")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if *backend == "" {
		fmt.Fprintln(os.Stderr, "backend URL is required")
		return 2
	}
	normalized, err := normalizeBackend(*backend)
	if err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		return 2
	}
	state, err := loadOrCreate(*data)
	if err != nil {
		fmt.Fprintln(os.Stderr, "state error")
		return 1
	}
	if state.Token != "" {
		fmt.Fprintln(os.Stderr, "agent is already paired")
		return 0
	}
	if state.Code == "" {
		state.Code = newPairingCode()
		if err := saveState(*data, state); err != nil {
			fmt.Fprintln(os.Stderr, "state error")
			return 1
		}
	}
	client := clientFrom(state, normalized)
	if err := client.Enroll(context.Background(), state.Code, localReport()); err != nil {
		fmt.Fprintln(os.Stderr, "panel did not accept enrollment")
		return 1
	}
	state.EnrollmentID = client.EnrollmentID
	state.Nonce = client.Nonce
	if err := saveState(*data, state); err != nil {
		fmt.Fprintln(os.Stderr, "state error")
		return 1
	}
	fmt.Printf("PAIRING CODE: %s\n", state.Code)
	fmt.Fprintln(os.Stderr, "code expires in 15 minutes and works once")
	return 0
}

func printCode(args []string) int {
	flags := flag.NewFlagSet("code", flag.ContinueOnError)
	data := flags.String("data", "/var/lib/family-vpn", "state directory")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	state, err := loadState(*data)
	if err != nil || state.Code == "" || state.Token != "" {
		fmt.Fprintln(os.Stderr, "no active pairing code")
		return 1
	}
	fmt.Println(state.Code)
	return 0
}

func runLoop(args []string) int {
	flags := flag.NewFlagSet("run", flag.ContinueOnError)
	backend := flags.String("backend", "", "panel base URL")
	data := flags.String("data", "/var/lib/family-vpn", "state directory")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if *backend == "" {
		fmt.Fprintln(os.Stderr, "backend URL is required")
		return 2
	}
	normalized, err := normalizeBackend(*backend)
	if err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		return 2
	}
	state, err := loadState(*data)
	if err != nil {
		fmt.Fprintln(os.Stderr, "state error")
		return 1
	}
	client := clientFrom(state, normalized)
	ctx := context.Background()
	if client.Token == "" {
		if client.EnrollmentID == "" || client.Nonce == "" {
			fmt.Fprintln(os.Stderr, "run enroll before the service")
			return 1
		}
		for {
			status, err := client.Poll(ctx)
			if errors.Is(err, ErrExpired) {
				fmt.Fprintln(os.Stderr, "pairing code expired")
				return 1
			}
			if errors.Is(err, ErrRevoked) {
				fmt.Fprintln(os.Stderr, "agent access revoked")
				return 0
			}
			if err != nil {
				time.Sleep(2 * time.Second)
				continue
			}
			if status == "paired" && client.Token != "" {
				state.Token = client.Token
				state.Code = ""
				if err := saveState(*data, state); err != nil {
					fmt.Fprintln(os.Stderr, "state error")
					return 1
				}
				break
			}
			time.Sleep(2 * time.Second)
		}
	}
	delay := time.Second
	for {
		err := client.Heartbeat(ctx, localReport())
		if errors.Is(err, ErrRevoked) {
			fmt.Fprintln(os.Stderr, "agent access revoked")
			return 0
		}
		if err != nil {
			time.Sleep(delay)
			if delay < 30*time.Second {
				delay *= 2
			}
			continue
		}
		delay = time.Second
		time.Sleep(15 * time.Second)
	}
}

func clientFrom(state *stateFile, backend string) *Client {
	private, _ := base64.RawURLEncoding.DecodeString(state.Private)
	public, _ := base64.RawURLEncoding.DecodeString(state.Public)
	return &Client{
		BaseURL:      backend,
		Public:       ed25519.PublicKey(public),
		Private:      ed25519.PrivateKey(private),
		EnrollmentID: state.EnrollmentID,
		Nonce:        state.Nonce,
		Token:        state.Token,
	}
}

func loadOrCreate(dir string) (*stateFile, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	state, err := loadState(dir)
	if err == nil {
		return state, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	state = &stateFile{
		Public:  base64.RawURLEncoding.EncodeToString(public),
		Private: base64.RawURLEncoding.EncodeToString(private),
	}
	if err := saveState(dir, state); err != nil {
		return nil, err
	}
	return state, nil
}

func loadState(dir string) (*stateFile, error) {
	raw, err := os.ReadFile(filepath.Join(dir, "agent.json"))
	if err != nil {
		return nil, err
	}
	var state stateFile
	if err := json.Unmarshal(raw, &state); err != nil {
		return nil, err
	}
	return &state, nil
}

func saveState(dir string, state *stateFile) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	raw, err := json.Marshal(state)
	if err != nil {
		return err
	}
	path := filepath.Join(dir, "agent.json")
	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, raw, 0o600); err != nil {
		return err
	}
	return os.Rename(temporary, path)
}

func newPairingCode() string {
	const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	raw := make([]byte, 20)
	for i := 0; i < len(raw); {
		var one [1]byte
		if _, err := rand.Read(one[:]); err != nil {
			panic("random source failed")
		}
		if int(one[0]) >= 256-(256%len(alphabet)) {
			continue
		}
		raw[i] = alphabet[int(one[0])%len(alphabet)]
		i++
	}
	return string(raw[0:5]) + "-" + string(raw[5:10]) + "-" + string(raw[10:15]) + "-" + string(raw[15:20])
}
