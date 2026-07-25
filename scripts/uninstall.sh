#!/bin/zsh
set -euo pipefail

AGENT_LABEL=local.codex.usage-agent
LAUNCH_AGENT_PATH="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
USER_DOMAIN="gui/$(id -u)"

launchctl bootout "$USER_DOMAIN/$AGENT_LABEL" 2>/dev/null || true
rm -f "$LAUNCH_AGENT_PATH"

pkill -x CodexUsageAgent 2>/dev/null || true
pkill -x CodexUsageWidgetExtension 2>/dev/null || true

for APP_PATH in \
    "/Applications/Codex 用量.app" \
    "$HOME/Applications/Codex 用量.app"
do
    if [[ -e "$APP_PATH" ]]; then
        rm -rf "$APP_PATH"
        echo "Removed: $APP_PATH"
    fi
done

killall chronod 2>/dev/null || true
killall NotificationCenter 2>/dev/null || true

echo "Codex 用量 has been uninstalled."
