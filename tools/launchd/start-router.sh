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
# One script, every machine: a host with its own fixtures/<host>-router/ runs
# that group; everything else runs the MBP's fixtures/router/. The mini also
# needs --targets, so that `host: macmini` resolves to local execution rather
# than the ssh-to-self the default targets encode, and --tailnet-read, so the
# MBP can watch this group's /state (read-only: /control stays local; see
# core/src/Bosun/ResidentAccess.purs).
case "$(scutil --get LocalHostName 2>/dev/null | tr '[:upper:]' '[:lower:]')" in
  *mac-mini*)
    # ON THE BEAM since 2026-11-16: the Mini is the test bed for beam/bosun
    # (docs/kb/plans/conformance-and-subsidiarity.md, step 3), because breaking
    # Marginalia and Infovore costs less than breaking Atlantis. Needs
    # beam/build.sh to have been run. To go back, replace `beam/bosun` with
    # `node cli/run.js` and
    #   launchctl kickstart -k gui/$(id -u)/net.hylograph.bosun-router
    exec beam/bosun --targets fixtures/macmini-router/targets.json \
      supervise --tailnet-read --port 3990 fixtures/macmini-router/compose.yml fixtures/macmini-router/registry.json ;;
esac
# The MBP's root: ON THE BEAM since 2026-11-17, after the Mini's root (16
# November) and the three group supervisors. Needs beam/build.sh to have been
# run. `bosun serve`, which this root launches, is still node. To go back,
# replace `beam/bosun` with `node cli/run.js` and
#   launchctl kickstart -k gui/$(id -u)/net.hylograph.bosun-router
exec beam/bosun supervise --port 3990 fixtures/router/compose.yml fixtures/router/registry.json
