package main

import (
	"bufio"
	"bytes"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

func localReport() Report {
	report := Report{InterfaceName: "wg0", InterfaceUp: false}
	report.Endpoint = localAddress()
	report.ExternalInterface = defaultInterface()
	output, err := exec.Command("wg", "show", "wg0").Output()
	if err != nil {
		report.ListenPort = configuredPort()
		return report
	}
	report.ExistingConfig = true
	report.InterfaceUp = true
	scanner := bufio.NewScanner(bytes.NewReader(output))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		switch {
		case strings.HasPrefix(line, "public key:"):
			report.PublicKey = strings.TrimSpace(strings.TrimPrefix(line, "public key:"))
		case strings.HasPrefix(line, "listening port:"):
			port := strings.TrimSpace(strings.TrimPrefix(line, "listening port:"))
			report.ListenPort = atoi(port)
		}
	}
	if report.ListenPort == 0 {
		report.ListenPort = configuredPort()
	}
	report.Subnet = interfaceSubnet()
	return report
}

func localAddress() string {
	output, err := exec.Command("ip", "-4", "route", "get", "1.1.1.1").Output()
	if err != nil {
		return ""
	}
	fields := strings.Fields(string(output))
	for i := 0; i < len(fields)-1; i++ {
		if fields[i] == "src" {
			return fields[i+1]
		}
	}
	return ""
}

func defaultInterface() string {
	output, err := exec.Command("ip", "-4", "route", "show", "default").Output()
	if err != nil {
		return ""
	}
	fields := strings.Fields(string(output))
	for i := 0; i < len(fields)-1; i++ {
		if fields[i] == "dev" {
			return fields[i+1]
		}
	}
	return ""
}

func interfaceSubnet() string {
	output, err := exec.Command("ip", "-4", "addr", "show", "dev", "wg0").Output()
	if err != nil {
		return ""
	}
	fields := strings.Fields(string(output))
	for i := 0; i < len(fields)-1; i++ {
		if fields[i] == "inet" {
			return networkCIDR(fields[i+1])
		}
	}
	return ""
}

func configuredPort() int {
	file, err := os.Open("/etc/wireguard/wg0.conf")
	if err != nil {
		return 0
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		lower := strings.ToLower(line)
		if strings.HasPrefix(lower, "privatekey") || strings.HasPrefix(lower, "#") {
			continue
		}
		if strings.HasPrefix(lower, "listenport") {
			parts := strings.SplitN(line, "=", 2)
			if len(parts) == 2 {
				return atoi(strings.TrimSpace(parts[1]))
			}
		}
	}
	return 0
}

func networkCIDR(value string) string {
	ip, network, err := net.ParseCIDR(value)
	if err != nil || ip.To4() == nil {
		return ""
	}
	ones, _ := network.Mask.Size()
	return network.IP.String() + "/" + strconv.Itoa(ones)
}

func atoi(value string) int {
	n := 0
	for _, char := range value {
		if char < '0' || char > '9' {
			return 0
		}
		n = n*10 + int(char-'0')
	}
	return n
}
