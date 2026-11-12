package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
)

var wgConfPath = "/etc/wireguard/wg0.conf"

var (
	wgKeyPattern     = regexp.MustCompile(`^[A-Za-z0-9+/]{42,44}={0,2}$`)
	allowedIPPattern = regexp.MustCompile(`^(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)/(?:3[0-2]|[12]?\d)$`)
	ipv4Pattern      = regexp.MustCompile(`^(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$`)
)

type PeerStat struct {
	PublicKey     string `json:"publicKey"`
	AllowedIPs    string `json:"allowedIps,omitempty"`
	RxBytes       int64  `json:"rxBytes"`
	TxBytes       int64  `json:"txBytes"`
	LastHandshake int64  `json:"lastHandshake"`
}

type Job struct {
	ID         string `json:"id"`
	Type       string `json:"type"`
	PublicKey  string `json:"publicKey"`
	AllowedIPs string `json:"allowedIps,omitempty"`
}

type JobResult struct {
	ID    string `json:"id"`
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

func collectPeerStats() []PeerStat {
	output, err := exec.Command("wg", "show", "wg0", "dump").Output()
	if err != nil {
		return nil
	}
	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	if len(lines) <= 1 {
		return nil
	}
	peers := make([]PeerStat, 0, len(lines)-1)
	for _, line := range lines[1:] {
		fields := strings.Split(line, "\t")
		if len(fields) < 8 {
			continue
		}
		publicKey := fields[0]
		if !validWgKey(publicKey) {
			continue
		}
		peers = append(peers, PeerStat{
			PublicKey:     publicKey,
			AllowedIPs:    fields[3],
			LastHandshake: atoi64(fields[4]),
			RxBytes:       atoi64(fields[5]),
			TxBytes:       atoi64(fields[6]),
		})
	}
	return peers
}

func applyJobs(jobs []Job) []JobResult {
	results := make([]JobResult, 0, len(jobs))
	for _, job := range jobs {
		results = append(results, applyJob(job))
	}
	return results
}

func applyJob(job Job) JobResult {
	if strings.TrimSpace(job.ID) == "" {
		return JobResult{ID: job.ID, OK: false, Error: "job id missing"}
	}
	if !validWgKey(job.PublicKey) {
		return JobResult{ID: job.ID, OK: false, Error: "public key rejected"}
	}
	switch job.Type {
	case "add_peer":
		if err := addPeer(job.PublicKey, job.AllowedIPs); err != nil {
			return JobResult{ID: job.ID, OK: false, Error: "add peer failed"}
		}
		return JobResult{ID: job.ID, OK: true}
	case "remove_peer":
		if err := removePeer(job.PublicKey); err != nil {
			return JobResult{ID: job.ID, OK: false, Error: "remove peer failed"}
		}
		return JobResult{ID: job.ID, OK: true}
	default:
		return JobResult{ID: job.ID, OK: false, Error: "unknown job"}
	}
}

func addPeer(publicKey, allowedIPs string) error {
	if err := validatePeerAllowedIPs(allowedIPs); err != nil {
		return err
	}
	if err := exec.Command("wg", "set", "wg0", "peer", publicKey, "allowed-ips", allowedIPs).Run(); err != nil {
		return err
	}
	return upsertPeerInConf(publicKey, allowedIPs)
}

func removePeer(publicKey string) error {
	_ = exec.Command("wg", "set", "wg0", "peer", publicKey, "remove").Run()
	return removePeerFromConf(publicKey)
}

func upsertPeerInConf(publicKey, allowedIPs string) error {
	raw, err := os.ReadFile(wgConfPath)
	if err != nil {
		return err
	}
	sections := splitConfSections(string(raw))
	found := false
	for i := range sections {
		if !strings.EqualFold(strings.TrimSpace(sections[i].header), "[Peer]") {
			continue
		}
		if peerPublicKey(sections[i].body) == publicKey {
			sections[i].body = peerBody(publicKey, allowedIPs)
			found = true
			break
		}
	}
	if !found {
		sections = append(sections, confSection{
			header: "[Peer]",
			body:   peerBody(publicKey, allowedIPs),
		})
	}
	return writeConfAtomic(joinConfSections(sections))
}

func removePeerFromConf(publicKey string) error {
	raw, err := os.ReadFile(wgConfPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	sections := splitConfSections(string(raw))
	filtered := make([]confSection, 0, len(sections))
	for _, section := range sections {
		if strings.EqualFold(strings.TrimSpace(section.header), "[Peer]") && peerPublicKey(section.body) == publicKey {
			continue
		}
		filtered = append(filtered, section)
	}
	return writeConfAtomic(joinConfSections(filtered))
}

type confSection struct {
	header string
	body   string
}

func splitConfSections(raw string) []confSection {
	scanner := bufio.NewScanner(strings.NewReader(raw))
	var sections []confSection
	var current *confSection
	var preamble strings.Builder
	for scanner.Scan() {
		line := scanner.Text()
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "[") && strings.HasSuffix(trimmed, "]") {
			if current == nil && preamble.Len() > 0 {
				sections = append(sections, confSection{header: "", body: preamble.String()})
				preamble.Reset()
			}
			sections = append(sections, confSection{header: trimmed})
			current = &sections[len(sections)-1]
			continue
		}
		if current == nil {
			preamble.WriteString(line)
			preamble.WriteByte('\n')
			continue
		}
		current.body += line + "\n"
	}
	if current == nil && preamble.Len() > 0 {
		sections = append(sections, confSection{header: "", body: preamble.String()})
	}
	return sections
}

func joinConfSections(sections []confSection) string {
	var out bytes.Buffer
	for index, section := range sections {
		if index > 0 && out.Len() > 0 && !strings.HasSuffix(out.String(), "\n\n") {
			if !strings.HasSuffix(out.String(), "\n") {
				out.WriteByte('\n')
			}
			out.WriteByte('\n')
		}
		if section.header != "" {
			out.WriteString(section.header)
			out.WriteByte('\n')
		}
		out.WriteString(strings.TrimRight(section.body, "\n"))
		if section.body != "" || section.header != "" {
			out.WriteByte('\n')
		}
	}
	if out.Len() > 0 && !strings.HasSuffix(out.String(), "\n") {
		out.WriteByte('\n')
	}
	return out.String()
}

func peerPublicKey(body string) string {
	scanner := bufio.NewScanner(strings.NewReader(body))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}
		if strings.EqualFold(strings.TrimSpace(parts[0]), "PublicKey") {
			return strings.TrimSpace(parts[1])
		}
	}
	return ""
}

func peerBody(publicKey, allowedIPs string) string {
	return "PublicKey = " + publicKey + "\nAllowedIPs = " + allowedIPs + "\n"
}

func writeConfAtomic(content string) error {
	temporary := wgConfPath + ".family-vpn.tmp"
	if err := os.WriteFile(temporary, []byte(content), 0o600); err != nil {
		return err
	}
	return os.Rename(temporary, wgConfPath)
}

func validWgKey(value string) bool {
	if !wgKeyPattern.MatchString(value) {
		return false
	}
	raw, err := base64.StdEncoding.DecodeString(value)
	return err == nil && len(raw) == 32
}

func validAllowedIPs(value string) bool {
	return validatePeerAllowedIPs(value) == nil
}

// Peer AllowedIPs must be a single IPv4 /32 inside the local wg0 VPN subnet,
// and must not equal the server Address host (FV-021).
func validatePeerAllowedIPs(value string) error {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" || strings.Contains(trimmed, ",") {
		return fmt.Errorf("allowed ips rejected")
	}
	if !allowedIPPattern.MatchString(trimmed) {
		return fmt.Errorf("allowed ips rejected")
	}
	if !strings.HasSuffix(trimmed, "/32") {
		return fmt.Errorf("allowed ips must be /32")
	}
	ip := strings.TrimSuffix(trimmed, "/32")
	subnet, serverHost, err := localVpnInfo()
	if err != nil {
		return err
	}
	if ip == serverHost {
		return fmt.Errorf("allowed ips must not be the server address")
	}
	if !ipv4InCidr(ip, subnet) {
		return fmt.Errorf("allowed ips outside vpn subnet")
	}
	return nil
}

func localVpnInfo() (subnetCIDR string, serverHost string, err error) {
	raw, readErr := os.ReadFile(wgConfPath)
	if readErr != nil {
		return "", "", readErr
	}
	scanner := bufio.NewScanner(strings.NewReader(string(raw)))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}
		if !strings.EqualFold(strings.TrimSpace(parts[0]), "Address") {
			continue
		}
		address := strings.TrimSpace(strings.Split(parts[1], ",")[0])
		host, prefix, parseErr := parseIPv4CIDR(address)
		if parseErr != nil {
			return "", "", parseErr
		}
		if prefix != 24 && prefix != 16 && prefix != 20 && prefix != 22 && prefix != 23 && prefix != 25 && prefix != 28 {
			// Accept common VPN prefixes; still require peer /32 inside the network.
		}
		network := ipv4Network(host, prefix)
		return fmt.Sprintf("%s/%d", network, prefix), host, nil
	}
	return "", "", fmt.Errorf("wg0 Address not found")
}

func parseIPv4CIDR(value string) (string, int, error) {
	parts := strings.Split(value, "/")
	if len(parts) != 2 {
		return "", 0, fmt.Errorf("invalid cidr")
	}
	prefix, err := strconv.Atoi(parts[1])
	if err != nil || prefix < 8 || prefix > 32 {
		return "", 0, fmt.Errorf("invalid prefix")
	}
	if !ipv4Pattern.MatchString(parts[0]) {
		return "", 0, fmt.Errorf("invalid ipv4")
	}
	return parts[0], prefix, nil
}

func ipv4Network(host string, prefix int) string {
	ip := ipv4ToInt(host)
	mask := uint32(0xFFFFFFFF) << (32 - prefix)
	if prefix == 0 {
		mask = 0
	}
	return intToIPv4(ip & mask)
}

func ipv4InCidr(host, cidr string) bool {
	parts := strings.Split(cidr, "/")
	if len(parts) != 2 {
		return false
	}
	prefix, err := strconv.Atoi(parts[1])
	if err != nil {
		return false
	}
	network := ipv4ToInt(parts[0])
	ip := ipv4ToInt(host)
	mask := uint32(0xFFFFFFFF) << (32 - prefix)
	if prefix == 0 {
		mask = 0
	}
	return (ip & mask) == (network & mask)
}

func ipv4ToInt(value string) uint32 {
	fields := strings.Split(value, ".")
	if len(fields) != 4 {
		return 0
	}
	var out uint32
	for _, field := range fields {
		n, _ := strconv.Atoi(field)
		out = (out << 8) | uint32(n&0xff)
	}
	return out
}

func intToIPv4(value uint32) string {
	return fmt.Sprintf("%d.%d.%d.%d", byte(value>>24), byte(value>>16), byte(value>>8), byte(value))
}

func atoi64(value string) int64 {
	n, err := strconv.ParseInt(strings.TrimSpace(value), 10, 64)
	if err != nil || n < 0 {
		return 0
	}
	return n
}
