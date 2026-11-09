package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestVersionFlag(t *testing.T) {
	bin := buildTestAgent(t)
	for _, args := range [][]string{{"--version"}, {"version"}, {"-version"}} {
		out, err := exec.Command(bin, args...).CombinedOutput()
		if err != nil {
			t.Fatalf("%v: %v (%s)", args, err, out)
		}
		got := strings.TrimSpace(string(out))
		if got != agentVersion {
			t.Fatalf("%v: got %q want %q", args, got, agentVersion)
		}
		if strings.Contains(got, "24.04") || strings.Contains(strings.ToLower(got), "noble") {
			t.Fatalf("%v leaked distro version: %q", args, got)
		}
	}
}

func buildTestAgent(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, "family-vpn-agent")
	if runtime.GOOS == "windows" {
		bin += ".exe"
	}
	cmd := exec.Command("go", "build", "-o", bin, ".")
	cmd.Dir = filepath.Dir(mustAbs(t, "main.go"))
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("go build: %v (%s)", err, out)
	}
	return bin
}

func mustAbs(t *testing.T, name string) string {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	return filepath.Join(wd, name)
}
