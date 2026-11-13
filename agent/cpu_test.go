package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCPUPercentFromProcStat(t *testing.T) {
	previous := mustParse(t, "cpu  100 0 100 700 100 0 0 0 9 9")
	current := mustParse(t, "cpu  200 0 200 1400 200 0 0 0 9 9")
	// Busy grew by 200 of 1000 jiffies. Guest columns must not change the result.
	percent, ok := cpuPercent(previous, current)
	if !ok || percent != 20 {
		t.Fatalf("percent=%d ok=%v", percent, ok)
	}
}

func TestCPUFirstSampleHasNoPercent(t *testing.T) {
	current := mustParse(t, "cpu  10 0 10 80 0 0 0 0")
	percent, ok := samplePercent(nil, current)
	if ok || percent != nil {
		t.Fatalf("first sample returned %v", percent)
	}
}

func TestCPUZeroIntervalHasNoPercent(t *testing.T) {
	sample := mustParse(t, "cpu  10 0 10 80 0 0 0 0")
	if percent, ok := cpuPercent(sample, sample); ok || percent != 0 {
		t.Fatalf("zero interval returned %d ok=%v", percent, ok)
	}
}

func TestCPUInvalidStatHasNoPercent(t *testing.T) {
	if _, err := parseCPUFields(nil); err == nil {
		t.Fatal("missing fields were accepted")
	}
	if _, err := parseCPUFields([]string{"1", "2", "nope", "4"}); err == nil {
		t.Fatal("non-numeric stat was accepted")
	}
	ahead := mustParse(t, "cpu  5 0 5 20 0 0 0 0")
	backwards := mustParse(t, "cpu  1 0 1 1 0 0 0 0")
	if _, ok := cpuPercent(ahead, backwards); ok {
		t.Fatal("backwards counter was accepted")
	}
}

func TestCPUSampleFileIgnoresPerCPULines(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "stat")
	body := "cpu0 100 0 0 0 0 0 0 0\ncpu  4 0 0 6 0 0 0 0\n"
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	old := procStatPath
	procStatPath = path
	t.Cleanup(func() { procStatPath = old })
	sample, err := readCPUSample()
	if err != nil {
		t.Fatal(err)
	}
	if sample.total != 10 || sample.idle != 6 {
		t.Fatalf("sample=%+v", sample)
	}
}

func TestReportOmitsCPUUntilMeasured(t *testing.T) {
	without, err := json.Marshal(Report{Endpoint: "203.0.113.10"})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(without), "cpuPercent") {
		t.Fatalf("empty cpu was serialized: %s", without)
	}
	percent := 18
	with, err := json.Marshal(Report{CpuPercent: &percent})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(with), `"cpuPercent":18`) {
		t.Fatalf("cpu was not serialized: %s", with)
	}
}

func samplePercent(previous *cpuSample, current cpuSample) (*int, bool) {
	if previous == nil {
		return nil, false
	}
	percent, ok := cpuPercent(*previous, current)
	if !ok {
		return nil, false
	}
	return &percent, true
}

func mustParse(t *testing.T, line string) cpuSample {
	t.Helper()
	fields := strings.Fields(line)
	if len(fields) == 0 || fields[0] != "cpu" {
		t.Fatalf("fixture is not an aggregate cpu line: %q", line)
	}
	sample, err := parseCPUFields(fields[1:])
	if err != nil {
		t.Fatal(err)
	}
	return sample
}
