#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
PROJECT_DIRECTORY=${SCRIPT_DIRECTORY:h}
APP_NAME="Codex 用量"
AGENT_LABEL=local.codex.usage-agent
LAUNCH_AGENT_PATH="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

if [[ -w /Applications ]]; then
    INSTALL_DIRECTORY=/Applications
else
    INSTALL_DIRECTORY="$HOME/Applications"
fi

APP_PATH="$INSTALL_DIRECTORY/$APP_NAME.app"
AGENT_PATH="$APP_PATH/Contents/Helpers/CodexUsageAgent"

"$SCRIPT_DIRECTORY/package-app.sh"

mkdir -p "$INSTALL_DIRECTORY" "$HOME/Library/LaunchAgents"
pkill -x CodexUsageWidget 2>/dev/null || true
ditto "$PROJECT_DIRECTORY/dist/$APP_NAME.app" "$APP_PATH"

cp "$PROJECT_DIRECTORY/Resources/$AGENT_LABEL.plist" "$LAUNCH_AGENT_PATH"
/usr/libexec/PlistBuddy \
    -c "Set :ProgramArguments:0 $AGENT_PATH" \
    "$LAUNCH_AGENT_PATH"
plutil -lint "$LAUNCH_AGENT_PATH"

pluginkit -a "$APP_PATH/Contents/PlugIns/CodexUsageWidgetExtension.appex"
pluginkit -e use -i local.codex.usage-widget.widget

USER_DOMAIN="gui/$(id -u)"
launchctl bootout "$USER_DOMAIN/$AGENT_LABEL" 2>/dev/null || true
launchctl bootstrap "$USER_DOMAIN" "$LAUNCH_AGENT_PATH"
launchctl enable "$USER_DOMAIN/$AGENT_LABEL"
launchctl kickstart -k "$USER_DOMAIN/$AGENT_LABEL"

# Runs once to unregister the legacy menu-bar login item, then exits immediately.
open "$APP_PATH"

echo "Installed: $APP_PATH"
echo "Next: Control-click the desktop, choose Edit Widgets, and search for Codex 用量."
