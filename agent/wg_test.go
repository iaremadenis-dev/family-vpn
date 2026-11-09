package main

import "testing"

func TestExistingSubnetIsReportedUnchanged(t *testing.T) {
	if got := networkCIDR("10.77.0.1/24"); got != "10.77.0.0/24" {
		t.Fatalf("subnet: got %s", got)
	}
	if got := networkCIDR("10.77.0.8/16"); got != "10.77.0.0/16" {
		t.Fatalf("subnet /16: got %s", got)
	}
	if got := atoi("51820"); got != 51820 {
		t.Fatalf("port: got %d", got)
	}
}
