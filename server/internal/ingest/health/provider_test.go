package health

import (
	"errors"
	"testing"
)

// TestAllowlistReloadsOnceOnUnknownName exists because the allowlist snapshot
// is cached for minutes: a name allowed by a migration a moment ago must be
// accepted after one reload, and a payload with several unknown names must
// not reload once per name.
func TestAllowlistReloadsOnceOnUnknownName(t *testing.T) {
	refreshes := 0
	a := allowlist{
		names: map[string]bool{"heart_rate": true},
		refresh: func() (map[string]bool, error) {
			refreshes++
			return map[string]bool{"heart_rate": true, "muscle_mass": true}, nil
		},
	}

	if !a.allows("heart_rate") {
		t.Fatal("known name rejected")
	}
	if refreshes != 0 {
		t.Fatalf("refreshes = %d after a hit, want 0", refreshes)
	}
	if !a.allows("muscle_mass") {
		t.Fatal("name present after reload was rejected")
	}
	if a.allows("unknown_a") || a.allows("unknown_b") {
		t.Fatal("name absent from the fresh snapshot was accepted")
	}
	if refreshes != 1 {
		t.Fatalf("refreshes = %d, want exactly 1 for the whole payload", refreshes)
	}
}

// TestAllowlistKeepsSnapshotWhenReloadFails exists so a failed reload behaves
// like the old single query: the names already known stay accepted and the
// unknown one is rejected, rather than the whole payload failing.
func TestAllowlistKeepsSnapshotWhenReloadFails(t *testing.T) {
	a := allowlist{
		names:   map[string]bool{"heart_rate": true},
		refresh: func() (map[string]bool, error) { return nil, errors.New("db down") },
	}
	if a.allows("muscle_mass") {
		t.Fatal("unknown name accepted after a failed reload")
	}
	if !a.allows("heart_rate") {
		t.Fatal("known name rejected after a failed reload")
	}
}
