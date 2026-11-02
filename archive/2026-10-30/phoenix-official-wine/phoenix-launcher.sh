#!/bin/zsh
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Run Phoenix's unmodified launcher in a dedicated Wine prefix. No game/addon injection.
set -euo pipefail
umask 077
[[ $# == 2 && -x "$1" && "$2" == /* && "$2" != / ]] || { print -u2 'Phoenix requires a Wine executable and a dedicated absolute folder.'; exit 2; }
WINE="$1"
ROOT="${2:A}"
mkdir -p "$ROOT/downloads" "$ROOT/logs"
LOCK="$ROOT/.launcher-lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [[ "$pid" == <-> ]] && kill -0 "$pid" 2>/dev/null; then
    print 'Phoenix is already open. Use its existing window.'; exit 0
  fi
  # Only this lock's two known paths; never remove an arbitrary directory tree.
  rm -f "$LOCK/pid"
  rmdir "$LOCK" 2>/dev/null || { print -u2 'Phoenix lock needs inspection.'; exit 1; }
  mkdir "$LOCK"
fi
print $$ > "$LOCK/pid"
trap 'rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true' EXIT
export WINEPREFIX="$ROOT/prefix"
export WINEDEBUG=-all
export WINEDLLOVERRIDES='mscoree,mshtml='
export WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS='--no-sandbox --disable-features=RendererCodeIntegrity --enable-logging=stderr'
# These are first-install pins. Phoenix handles its own subsequent updates.
fetch() {
  local url="$1" file="$2" hash="$3"
  if [[ -f "$file" ]] && [[ "$(shasum -a 256 "$file" | cut -d ' ' -f 1)" == "$hash" ]]; then return; fi
  curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 600 "$url" -o "$file.part"
  [[ "$(shasum -a 256 "$file.part" | cut -d ' ' -f 1)" == "$hash" ]] || { print -u2 'Official download changed. An updated launcher package is required; nothing was installed.'; exit 1; }
  mv "$file.part" "$file"
}
if [[ ! -d "$WINEPREFIX/drive_c" ]]; then
  print 'Preparing Phoenix Wine prefix…'
  "$WINE" wineboot -u > "$ROOT/logs/wineboot.log" 2>&1
fi
# Use the registry's real runtime installation check, not a marker file.
if ! "$WINE" reg query 'HKLM\Software\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' /v pv > "$ROOT/logs/webview-check.log" 2>&1; then
  print 'Installing Microsoft WebView2 for Phoenix…'
  fetch 'https://go.microsoft.com/fwlink/?linkid=2124701' "$ROOT/downloads/WebView2-x64.exe" '62863f0f0611a16ccf124b4f15650c3b66624504eba74d7cde1e2ae5d951249b'
  "$WINE" "$ROOT/downloads/WebView2-x64.exe" /silent /install > "$ROOT/logs/webview-install.log" 2>&1
fi
APP="$WINEPREFIX/drive_c/PhoenixLauncher/phoenix-launcher.exe"
if [[ ! -f "$APP" ]]; then
  print 'Installing the official Phoenix launcher…'
  fetch 'https://launcher.phoenix-xi.com/windows/Phoenix.Launcher_x64-setup.exe' "$ROOT/downloads/Phoenix-setup.exe" '1e9a143c428c9ac542f800330766e397455f1bbb12a43fec7c8531df9b4ea0c2'
  "$WINE" "$ROOT/downloads/Phoenix-setup.exe" /S '/D=C:\PhoenixLauncher' > "$ROOT/logs/phoenix-install.log" 2>&1
fi
[[ -f "$APP" ]] || { print -u2 'Phoenix installer did not create its launcher. See Phoenix logs.'; exit 1; }
print 'Opening Phoenix. Sign in and install the game in its own launcher.'
# Its authentication output stays private and is never copied to the shared launcher log.
cd "${APP:h}"
"$WINE" "$APP" > "$ROOT/logs/phoenix-runtime.log" 2>&1
