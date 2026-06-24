#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/Quake4Mac.xcodeproj/project.pbxproj"

fail() {
  printf 'security guard failed: %s\n' "$1" >&2
  exit 1
}

if rg -n 'DEVELOPMENT_TEAM = [^;]+;' "$PROJECT" >/dev/null; then
  fail "project must not pin an Apple Development Team ID"
fi

if ! awk '
  /\/\* Release \*\/ = \{/ { in_release = 1; found = 0 }
  in_release && /ENABLE_HARDENED_RUNTIME = YES;/ { found = 1 }
  in_release && /name = Release;/ { if (found) ok = 1; in_release = 0 }
  END { exit ok ? 0 : 1 }
' "$PROJECT"; then
  fail "Release build settings must enable hardened runtime"
fi

if rg -n 'UserDefaults\.standard\.(string|set|removeObject).*spotify\.refreshToken' "$ROOT/Quake4Mac" >/dev/null; then
  fail "Spotify refresh tokens must not be stored in UserDefaults"
fi

if ! rg -n 'MacroActionExecutor' "$ROOT/Quake4Mac" >/dev/null; then
  fail "shell and AppleScript macro execution must use the centralized executor"
fi

if ! rg -n 'settings\.developerMode' "$ROOT/Quake4Mac/App/Quake4MacApp.swift" >/dev/null; then
  fail "device-writing debug menu actions must be gated by developer mode"
fi

if rg -n -i --glob '*.swift' 'dfu|bootloader|dfu-util|avrdude|qmk flash|firmware flash|flash firmware|flashing firmware' \
  "$ROOT/Quake4Mac" >/dev/null ||
  rg -n -i 'dfu|bootloader|dfu-util|avrdude|qmk flash|firmware flash|flash firmware|flashing firmware' "$PROJECT" >/dev/null; then
  fail "firmware flashing / DFU code or commands are not allowed"
fi

if rg -n '<script[^>]+src="https?://|<link[^>]+href="https?://' "$ROOT/Quake4Mac/Web" --glob '*.html' >/dev/null; then
  fail "bundled web panels must not execute remote script or stylesheet resources"
fi

if ! rg -n 'function escHTML' "$ROOT/Quake4Mac/Web/monitor.html" >/dev/null; then
  fail "monitor web panel must escape system-provided strings before HTML insertion"
fi

if ! rg -n 'function safeBookmarkURL' "$ROOT/Quake4Mac/Web/browser-home.html" >/dev/null; then
  fail "browser home must validate bookmark URL schemes"
fi

if ! rg -n 'function escHTML' "$ROOT/Quake4Mac/Web/weather.html" >/dev/null; then
  fail "weather web panel must escape location names before HTML insertion"
fi

if ! rg -n 'isSafeWebURL' "$ROOT/Quake4Mac/Macro/MacroActionExecutor.swift" >/dev/null ||
  ! rg -n 'MacroActionExecutor\.webURL\(from:' "$ROOT/Quake4Mac/Clock/ClockScreen.swift" >/dev/null; then
  fail "macro URL actions and web dashboards must restrict URL schemes"
fi

if ! rg -n 'detach\(device:' "$ROOT/Quake4Mac/Device/QuakeInput.swift" >/dev/null; then
  fail "HID removal must unregister/close stale devices"
fi

if ! rg -n 'webViewWebContentProcessDidTerminate' "$ROOT/Quake4Mac/App" "$ROOT/Quake4Mac/Home" "$ROOT/Quake4Mac/Macro" >/dev/null ||
  ! rg -n 'webView\.reload\(\)|load\(html: htmlName\)|loadLocalPage\(\)' "$ROOT/Quake4Mac/App" "$ROOT/Quake4Mac/Home" "$ROOT/Quake4Mac/Macro" >/dev/null; then
  fail "persistent web views must reload after WebContent process termination"
fi

if ! rg -n 'macroTimeout' "$ROOT/Quake4Mac/Macro/MacroActionExecutor.swift" >/dev/null; then
  fail "executable macro processes must have timeout protection"
fi

if ! rg -n 'normalizePageIndex' "$ROOT/Quake4Mac/Macro/MacroPad.swift" >/dev/null; then
  fail "macro page navigation must clamp stale page indexes"
fi

if awk '
  /func warm\(\)/ { in_warm = 1 }
  in_warm && /LocationService\.shared\.request\(\)/ { bad = 1 }
  in_warm && /^    \}/ { in_warm = 0 }
  END { exit bad ? 0 : 1 }
' "$ROOT/Quake4Mac/Home/WeatherScreen.swift"; then
  fail "weather warm-up must not request location permission at app launch"
fi

printf 'security guards passed\n'
