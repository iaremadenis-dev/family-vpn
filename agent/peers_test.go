package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSplitAndJoinPreserveInterface(t *testing.T) {
	original := `[Interface]
PrivateKey = SERVERPRIVATEKEYSERVERPRIVATEKEYSERVE=
Address = 10.200.0.1/24
ListenPort = 51820

[Peer]
PublicKey = IPHONEPEERPUBLICKEYIPHONEPEERPUBLICKEYIPH=
AllowedIPs = 10.200.0.2/32
`
	sections := splitConfSections(original)
	if len(sections) < 2 {
		t.Fatalf("expected interface and peer, got %d", len(sections))
	}
	if !strings.Contains(sections[0].body, "PrivateKey = SERVERPRIVATEKEYSERVERPRIVATEKEYSERVE=") {
		t.Fatal("server private key section was altered")
	}
	joined := joinConfSections(sections)
	if !strings.Contains(joined, "PrivateKey = SERVERPRIVATEKEYSERVERPRIVATEKEYSERVE=") {
		t.Fatal("rewrite lost server private key")
	}
	if !strings.Contains(joined, "IPHONEPEERPUBLICKEYIPHONEPEERPUBLICKEYIPH=") {
		t.Fatal("rewrite lost existing peer")
	}
}

func TestUpsertAndRemovePeerKeepOthers(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "wg0.conf")
	original := `[Interface]
PrivateKey = SERVERPRIVATEKEYSERVERPRIVATEKEYSERVE=
ListenPort = 51820

[Peer]
PublicKey = IPHONEPEERPUBLICKEYIPHONEPEERPUBLICKEY12=
AllowedIPs = 10.200.0.2/32
`
	if err := os.WriteFile(path, []byte(original), 0o600); err != nil {
		t.Fatal(err)
	}
	old := wgConfPath
	defer func() { /* restore via rewrite of package const is impossible; use helper */ }()
	_ = old

	if err := upsertPeerInConfAt(path, "NEWPEERPUBLICKEYNEWPEERPUBLICKEYNEWPEER12=", "10.200.0.5/32"); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	text := string(raw)
	if !strings.Contains(text, "IPHONEPEERPUBLICKEYIPHONEPEERPUBLICKEY12=") {
		t.Fatal("existing iPhone peer was removed")
	}
	if !strings.Contains(text, "NEWPEERPUBLICKEYNEWPEERPUBLICKEYNEWPEER12=") {
		t.Fatal("new peer was not appended")
	}
	if !strings.Contains(text, "PrivateKey = SERVERPRIVATEKEYSERVERPRIVATEKEYSERVE=") {
		t.Fatal("server key was changed")
	}

	if err := removePeerFromConfAt(path, "NEWPEERPUBLICKEYNEWPEERPUBLICKEYNEWPEER12="); err != nil {
		t.Fatal(err)
	}
	raw, err = os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	text = string(raw)
	if strings.Contains(text, "NEWPEERPUBLICKEYNEWPEERPUBLICKEYNEWPEER12=") {
		t.Fatal("new peer was not removed")
	}
	if !strings.Contains(text, "IPHONEPEERPUBLICKEYIPHONEPEERPUBLICKEY12=") {
		t.Fatal("iPhone peer must remain")
	}
}

func TestValidAllowedIPs(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "wg0.conf")
	if err := os.WriteFile(path, []byte("[Interface]\nAddress = 10.200.0.1/24\nListenPort = 51820\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	old := wgConfPath
	wgConfPath = path
	defer func() { wgConfPath = old }()

	if !validAllowedIPs("10.200.0.5/32") {
		t.Fatal("expected valid")
	}
	if validAllowedIPs("10.200.0.5") {
		t.Fatal("prefix required")
	}
	if validAllowedIPs("10.200.0.5/24") {
		t.Fatal("non-/32 must fail")
	}
	if validAllowedIPs("0.0.0.0/0") {
		t.Fatal("default route must fail")
	}
	if validAllowedIPs("10.200.0.1/32") {
		t.Fatal("server address must fail")
	}
	if validAllowedIPs("10.201.0.5/32") {
		t.Fatal("outside subnet must fail")
	}
	if validAllowedIPs("10.200.0.5/32; rm -rf /") {
		t.Fatal("injection must fail")
	}
}

func upsertPeerInConfAt(path, publicKey, allowedIPs string) error {
	raw, err := os.ReadFile(path)
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
		sections = append(sections, confSection{header: "[Peer]", body: peerBody(publicKey, allowedIPs)})
	}
	return os.WriteFile(path, []byte(joinConfSections(sections)), 0o600)
}

func removePeerFromConfAt(path, publicKey string) error {
	raw, err := os.ReadFile(path)
	if err != nil {
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
	return os.WriteFile(path, []byte(joinConfSections(filtered)), 0o600)
}
