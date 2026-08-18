#!/bin/sh
# Rebuild the desktop panel and restart it.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"

swiftc -O -o "$DIR/agent-widgets" "$DIR/AgentWidgets.swift"

if launchctl print "gui/$(id -u)/ai.boringstack.agent-widgets" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/ai.boringstack.agent-widgets"
  echo "rebuilt and restarted"
else
  echo "rebuilt (agent not loaded — see README)"
fi
