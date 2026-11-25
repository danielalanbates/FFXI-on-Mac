#!/bin/zsh
# Play HorizonXI — runs the launcher with full permissions via Terminal context.
# Avoids Finder/LaunchServices TCC sandbox denials on external volume game data.
APP="/Applications/HorizonXI.app"

if [[ -d "$APP" ]]; then
  echo "==> Launching HorizonXI via Terminal context..."
  exec "$APP/Contents/MacOS/FFXI-on-Mac" --play "$@"
else
  echo "Error: $APP not found in /Applications" >&2
  exit 1
fi
