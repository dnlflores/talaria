#!/bin/bash
# Installs the talaria-push Hermes plugin on this Mac and enables it.
#
#   scripts/install-push-plugin.sh                      install or update the plugin
#   scripts/install-push-plugin.sh --key AuthKey_X.p8   also put an APNs key in place
#   scripts/install-push-plugin.sh --team ABCDE12345    record the team id the key belongs to
#
# The plugin's routes mount on the first request after it is enabled, so no gateway restart is
# needed; the app's next registration (opening it, or Settings > Notifications) starts it.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
home="${HERMES_HOME:-$HOME/.hermes}"
plugin="$home/plugins/talaria-push"
data="$home/plugin-data/talaria-push"
hermes="$(command -v hermes || true)"
[ -n "$hermes" ] || hermes="$home/hermes-agent/venv/bin/hermes"

key=""
team=""
while [ $# -gt 0 ]; do
  case "$1" in
    --key) key="$2"; shift 2 ;;
    --team) team="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$home/plugins" "$data"
chmod 700 "$data"
rsync -a --delete --exclude '__pycache__' --exclude 'tests' "$repo/mac/talaria-push/" "$plugin/"
"$hermes" plugins enable talaria-push --no-allow-tool-override

if [ -n "$key" ]; then
  name="$(basename "$key")"
  case "$name" in
    AuthKey_*.p8) ;;
    *) echo "expected the AuthKey_<KEYID>.p8 file Apple's developer site gives you" >&2; exit 2 ;;
  esac
  install -m 600 "$key" "$data/$name"
  echo "APNs key $name is in $data"
fi

if [ -n "$team" ]; then
  printf '{"team_id": "%s"}\n' "$team" > "$data/config.json"
  chmod 600 "$data/config.json"
fi

echo "talaria-push is installed in $plugin and enabled."
ls "$data"/AuthKey_*.p8 >/dev/null 2>&1 || echo "No APNs key yet: rerun with --key <AuthKey_XXXXXXXXXX.p8>."
