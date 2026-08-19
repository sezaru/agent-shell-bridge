#!/usr/bin/env bash
# Run the agent-shell CONTRACT tests against the REAL agent-shell package.
#
# The contract tests load the actual agent-shell (not a stub), so an upstream
# change to an internal we depend on fails here instead of silently at runtime.
#
# agent-shell + its deps live on the interactive Emacs's load-path (a nix elpa
# tree), which a bare `emacs --batch` does not see. We snapshot that load-path
# from a running Emacs server once (cached in test/.load-path.el), then run
# batch ERT with it. Refresh the cache after an agent-shell update:
#     rm test/.load-path.el && test/run-contract.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
EMACS="${EMACS:-emacs}"
SERVER="${ASB_EMACS_SERVER:-asb-gui}"
LP="$REPO/test/.load-path.el"

if [ ! -f "$LP" ]; then
  echo "snapshotting load-path from emacs server '$SERVER'..." >&2
  emacsclient -s "$SERVER" --eval \
    "(with-temp-file \"$LP\" (prin1 load-path (current-buffer)))" >/dev/null
fi

exec "$EMACS" -Q --batch \
  --eval "(setq load-path (with-temp-buffer (insert-file-contents \"$LP\") (read (current-buffer))))" \
  -L "$REPO" -L "$REPO/test" \
  -l ert \
  -l "$REPO/test/agent-shell-bridge-contract-test.el" \
  -f ert-run-tests-batch-and-exit
