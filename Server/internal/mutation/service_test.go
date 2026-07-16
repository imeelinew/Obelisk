package mutation

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestLogicalTimestampHasDeterministicTotalOrder(t *testing.T) {
	deviceA := uuid.MustParse("00000000-0000-0000-0000-00000000000a")
	deviceB := uuid.MustParse("00000000-0000-0000-0000-00000000000b")
	first := LogicalTimestamp{Milliseconds: 100, Counter: 1, DeviceID: deviceA}
	second := LogicalTimestamp{Milliseconds: 100, Counter: 1, DeviceID: deviceB}
	if !second.After(first) || first.After(second) {
		t.Fatal("device ID did not break a concurrent timestamp tie")
	}
}

func TestMergeFieldsOnlyAppliesNewerFieldVersions(t *testing.T) {
	device := uuid.New()
	old := LogicalTimestamp{Milliseconds: 100, DeviceID: device}
	newer := LogicalTimestamp{Milliseconds: 101, DeviceID: device}
	values := map[string]json.RawMessage{
		"name":         json.RawMessage(`"new name"`),
		"show_in_menu": json.RawMessage(`true`),
	}
	columns, arguments, versions, err := mergeFields(
		values,
		collectionFields,
		map[string]LogicalTimestamp{"name": newer, "show_in_menu": old},
		map[string]LogicalTimestamp{"name": old, "show_in_menu": newer},
		device,
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(columns) != 1 || columns[0] != "name" || arguments[0] != "new name" {
		t.Fatalf("unexpected merge: columns=%v arguments=%v", columns, arguments)
	}
	if versions["name"] != newer || versions["show_in_menu"] != newer {
		t.Fatal("field versions were not merged independently")
	}
}

func TestMergeRejectsVersionFromAnotherDevice(t *testing.T) {
	device := uuid.New()
	_, _, _, err := mergeFields(
		map[string]json.RawMessage{"name": json.RawMessage(`"name"`)},
		collectionFields,
		map[string]LogicalTimestamp{
			"name": {Milliseconds: 100, DeviceID: uuid.New()},
		},
		map[string]LogicalTimestamp{},
		device,
	)
	if err == nil {
		t.Fatal("accepted a forged device timestamp")
	}
}

func TestMergeIgnoresStaleVersionFromAnotherDevice(t *testing.T) {
	localDevice := uuid.New()
	remoteDevice := uuid.New()
	remoteVersion := LogicalTimestamp{Milliseconds: 100, DeviceID: remoteDevice}
	columns, arguments, versions, err := mergeFields(
		map[string]json.RawMessage{"name": json.RawMessage(`"stale name"`)},
		collectionFields,
		map[string]LogicalTimestamp{"name": remoteVersion},
		map[string]LogicalTimestamp{"name": remoteVersion},
		localDevice,
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(columns) != 0 || len(arguments) != 0 || versions["name"] != remoteVersion {
		t.Fatalf("stale remote field was not ignored: columns=%v arguments=%v versions=%v", columns, arguments, versions)
	}
}

func TestRequiredBooleanAcceptsJSONAndSQLiteBooleans(t *testing.T) {
	t.Parallel()

	tests := []struct {
		raw  string
		want bool
	}{
		{raw: `true`, want: true},
		{raw: `false`, want: false},
		{raw: `1`, want: true},
		{raw: `0`, want: false},
	}
	for _, test := range tests {
		value, err := requiredBoolean(json.RawMessage(test.raw))
		if err != nil {
			t.Fatalf("requiredBoolean(%s): %v", test.raw, err)
		}
		if value != test.want {
			t.Fatalf("requiredBoolean(%s) = %v, want %v", test.raw, value, test.want)
		}
	}
}

func TestRequiredBooleanRejectsNonBooleanNumbers(t *testing.T) {
	t.Parallel()

	for _, raw := range []string{`2`, `-1`, `null`, `"true"`} {
		if _, err := requiredBoolean(json.RawMessage(raw)); err == nil {
			t.Fatalf("requiredBoolean(%s) unexpectedly succeeded", raw)
		}
	}
}

func TestBrowserHistoryAcceptsOnlyCanonicalBrowserIdentifiers(t *testing.T) {
	t.Parallel()

	for _, browser := range []string{
		"dia", "chrome", "safari",
	} {
		if !isSupportedBrowserHistoryBrowser(browser) {
			t.Fatalf("canonical browser %q was rejected", browser)
		}
	}
	for _, browser := range []string{"", "Chrome", "unknown"} {
		if isSupportedBrowserHistoryBrowser(browser) {
			t.Fatalf("invalid browser %q was accepted", browser)
		}
	}
}

func TestBrowserHistorySettingsAcceptCanonicalSourcesAndEmptySelection(t *testing.T) {
	t.Parallel()

	for _, raw := range []string{`""`, `"dia,chrome"`, `"dia,chrome,safari"`} {
		if _, err := requiredBrowserHistorySources(json.RawMessage(raw)); err != nil {
			t.Fatalf("requiredBrowserHistorySources(%s): %v", raw, err)
		}
	}
	for _, raw := range []string{`null`, `"Chrome"`, `"dia,dia"`, `"chrome,dia"`, `"unknown"`} {
		if _, err := requiredBrowserHistorySources(json.RawMessage(raw)); err == nil {
			t.Fatalf("requiredBrowserHistorySources(%s) unexpectedly succeeded", raw)
		}
	}
}

func TestDecodeBrowserHistoryPatchAcceptsAndOrdersMutableFields(t *testing.T) {
	columns, arguments, err := decodeBrowserHistoryPatch(map[string]json.RawMessage{
		"visited_at": json.RawMessage(`"2026-07-16T12:00:00.123Z"`),
		"title":      json.RawMessage(`"Updated title"`),
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(columns) != 2 || columns[0] != "title" || columns[1] != "visited_at" {
		t.Fatalf("unexpected columns: %v", columns)
	}
	if arguments[0] != "Updated title" {
		t.Fatalf("unexpected title: %v", arguments[0])
	}
	visitedAt, ok := arguments[1].(time.Time)
	if !ok || visitedAt.Format(time.RFC3339Nano) != "2026-07-16T12:00:00.123Z" {
		t.Fatalf("unexpected visited_at: %v", arguments[1])
	}
}

func TestDecodeBrowserHistoryPatchRejectsEmptyAndUnsupportedChanges(t *testing.T) {
	for name, values := range map[string]map[string]json.RawMessage{
		"empty":       {},
		"created_at":  {"created_at": json.RawMessage(`"2026-07-16T12:00:00Z"`)},
		"bad_browser": {"browser": json.RawMessage(`"unknown"`)},
		"bad_url":     {"url": json.RawMessage(`"file:///private/history"`)},
	} {
		t.Run(name, func(t *testing.T) {
			if _, _, err := decodeBrowserHistoryPatch(values); err == nil {
				t.Fatal("invalid browser history patch was accepted")
			}
		})
	}
}
