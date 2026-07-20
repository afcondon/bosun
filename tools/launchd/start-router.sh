#!/bin/bash
# bosun-router LaunchAgent entry point — the durable SDI replacement.
#
# The bootstrap top of the dogfood chain:
#   launchd → bosun supervise → bosun serve → lazy-spawned dev backends
#
# launchd keeps `bosun supervise` alive (KeepAlive); supervise keeps `bosun
# serve` alive (its keep-alive loop); serve lazy-spawns + idle-reaps the dev
# pages. launchd is just the macOS bootstrap that happens to sit on top — the
# portable part is `supervise → serve`, which runs identically on any target.
#
# node (and `npx`, which the lazy-spawned pages need) comes from the Nix
# profile (dev-tools→Nix sweep 2026-07-20); nvm remains only as a fallback
# until it is fully retired.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -x "$HOME/.nix-profile/bin/node" ]; then
  export PATH="$HOME/.nix-profile/bin:$PATH"
else
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1090
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
fi
cd "$SCRIPT_DIR/../.."   # tools/launchd → the bosun repo root
exec node cli/run.js supervise --port 3990 fixtures/router/compose.yml fixtures/router/registry.json
