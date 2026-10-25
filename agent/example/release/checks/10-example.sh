#!/bin/sh
# Example smoke check. Runs after activate and after the built-in xochitl
# check. Exit 0 = pass. Non-zero = the agent rolls back. Keep it fast
# (check_timeout_seconds, default 60) and side-effect free.
set -eu
test -d "$PP_RELEASE_DIR/hooks"
