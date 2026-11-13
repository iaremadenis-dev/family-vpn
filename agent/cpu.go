package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// procStatPath is the Linux aggregate CPU line. Tests may point it at a fixture.
var procStatPath = "/proc/stat"

type cpuSample struct {
	total uint64
	idle  uint64
}

// readCPUSample reads the aggregate "cpu " line. Guest jiffies are already
// included in user/nice, so they are not added again.
func readCPUSample() (cpuSample, error) {
	file, err := os.Open(procStatPath)
	if err != nil {
		return cpuSample{}, err
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) == 0 || fields[0] != "cpu" {
			continue
		}
		return parseCPUFields(fields[1:])
	}
	if err := scanner.Err(); err != nil {
		return cpuSample{}, err
	}
	return cpuSample{}, fmt.Errorf("cpu line missing")
}

func parseCPUFields(fields []string) (cpuSample, error) {
	// user, nice, system, idle, iowait, irq, softirq, steal
	if len(fields) < 4 {
		return cpuSample{}, fmt.Errorf("cpu line is incomplete")
	}
	var values [8]uint64
	limit := len(fields)
	if limit > 8 {
		limit = 8
	}
	for index := 0; index < limit; index++ {
		value, err := strconv.ParseUint(fields[index], 10, 64)
		if err != nil {
			return cpuSample{}, err
		}
		values[index] = value
	}
	var total uint64
	for _, value := range values {
		total += value
	}
	return cpuSample{total: total, idle: values[3] + values[4]}, nil
}

// cpuPercent is the busy share of the jiffy increase, rounded to 0–100.
// The first sample, a zero interval, and a backwards counter are not data.
func cpuPercent(previous, current cpuSample) (int, bool) {
	if current.total < previous.total || current.idle < previous.idle {
		return 0, false
	}
	total := current.total - previous.total
	idle := current.idle - previous.idle
	if total == 0 || idle > total {
		return 0, false
	}
	busy := total - idle
	percent := int((busy*100 + total/2) / total)
	if percent < 0 || percent > 100 {
		return 0, false
	}
	return percent, true
}
