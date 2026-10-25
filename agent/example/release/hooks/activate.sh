#!/bin/sh
# Example activate hook. The mods lane owns the real one.
#
# Contract (see agent/README.md, "Hooks"):
#   - make this release's mods live, e.g. restart xochitl with xovi loaded
#   - cwd is the release dir; env has PP_ROOT, PP_RELEASE_ID,
#     PP_RELEASE_DIR, PP_REASON (install|boot|rollback|manual-rollback|
#     tripletap), PP_OS_VERSION
#   - exit 0 = done, anything else = failure (the agent rolls back)
#   - finish within hook_timeout_seconds (default 120)
#   - anything that must outlive the hook goes through systemd-run or
#     systemctl, because the agent's unit is a oneshot and systemd kills
#     what it leaves behind
#   - idempotent: it can run twice in a row
set -eu
echo "activate $PP_RELEASE_ID ($PP_REASON) on OS $PP_OS_VERSION from $PWD"
