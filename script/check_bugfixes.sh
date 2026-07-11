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
grep -q 'ai_integration_enabled' ClipFlow/Services/OllamaService.swift || fail "AI integration toggle missing"
grep -q 'guard isEnabled else' ClipFlow/Services/OllamaService.swift || fail "AI service does not guard disabled state"
grep -q 'ollamaService.isEnabled' ClipFlow/Views/DetailView.swift || fail "detail view does not hide optional AI integration"
test -f ClipFlow/Services/TinyLocalAIService.swift || fail "bundled tiny local AI service missing"
grep -q 'func rewrite' ClipFlow/Services/TinyLocalAIService.swift || fail "tiny local AI cannot rewrite"
grep -q 'onRewrite' ClipFlow/Views/Components/AIGeneratingView.swift || fail "rewrite action missing from detail AI UI"
grep -q 'rewrite' ClipFlow/Views/SettingsView.swift || fail "API history does not label rewrite calls"
swiftc ClipFlow/Models/ClipboardItem.swift ClipFlow/Services/TinyLocalAIService.swift script/check_tiny_ai.swift -o /tmp/clipflow_check_tiny_ai
/tmp/clipflow_check_tiny_ai

echo "bugfix checks passed"
