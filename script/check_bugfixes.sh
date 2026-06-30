#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

grep -q 'Button(action: { onUpdateSummary(summary) })' ClipFlow/Views/DetailView.swift && fail "detail delete still saves summary"
grep -q 'guard recordedKeyCode > 0' ClipFlow/Views/SettingsView.swift && fail "shortcut recorder still rejects keyCode 0"
grep -q 'for row in try db!' ClipFlow/Services/DatabaseService.swift && fail "database fetch still force unwraps db"
grep -q 'names.contains("ai_summary")' ClipFlow/Services/DatabaseService.swift || fail "ai_summary migration missing"
grep -q 'NSEvent.removeMonitor' ClipFlow/Views/SettingsView.swift || fail "shortcut recorder does not remove local monitor"
grep -q 'settingsWindowDelegate' ClipFlow/App/AppDelegate.swift || fail "settings window delegate is not strongly retained"
grep -q 'onCopy:' ClipFlow/Views/ClipboardListView.swift || fail "list rows do not separate select from copy"
grep -q 'var selectedCategoryLabel: String?' ClipFlow/Views/ClipboardListView.swift || fail "list view does not receive selected category"
grep -q 'selectedCategoryLabel: selectedCategoryLabel' ClipFlow/Views/ContentView.swift || fail "content view does not pass selected category to list"
grep -q '.onChange(of: selectedCategoryLabel)' ClipFlow/Views/ClipboardListView.swift || fail "category changes do not clear stale search"
grep -q 'private var selectedCategoryLabel: String' ClipFlow/Views/ClipboardListView.swift && fail "list view still hardcodes empty selected category"

echo "bugfix checks passed"
