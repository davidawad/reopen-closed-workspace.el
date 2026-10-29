#!/usr/bin/env bash
# test_reopen_closed_workspace.sh -- reopen-closed-workspace's ERT suites, one
# batch Emacs at a time, after byte-compiling the package with warnings
# as errors.  Usage: test_reopen_closed_workspace.sh [suite-name...], where
# a suite name is a test/test-*.el basename without its extension; no
# argument runs them all.
#
# The engine, terra-emacs, comes from TERRA_EMACS_DIR (default: a sibling
# checkout, ../terra-emacs.el), the exporter from TERRA_EMACS_CAPTURE_DIR
# (default ../terra-emacs-capture.el).  eat and persp-mode come from
# TERRA_EMACS_TEST_PACKAGES (default /opt/emacs-test-packages), or from
# the colon-separated directories in TERRA_EMACS_TEST_LOAD_PATH, else
# from the user's own installed copies; tests needing one skip when it
# is missing.  reopen-closed-buffer, for the
# tests of `reopen-closed-last' with buffers, comes from
# REOPEN_CLOSED_BUFFER_DIR (default ../reopen-closed-buffer.el).
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(dirname "$TEST_DIR")"
EMACS_BIN="${EMACS:-emacs}"
ENGINE="${TERRA_EMACS_DIR:-$(dirname "$PKG_DIR")/terra-emacs.el}"
CAPTURE="${TERRA_EMACS_CAPTURE_DIR:-$(dirname "$PKG_DIR")/terra-emacs-capture.el}"
BUFFERS="${REOPEN_CLOSED_BUFFER_DIR:-$(dirname "$PKG_DIR")/reopen-closed-buffer.el}"
for pair in "terra-emacs:$ENGINE:TERRA_EMACS_DIR" "terra-emacs-capture:$CAPTURE:TERRA_EMACS_CAPTURE_DIR" \
            "reopen-closed-buffer:$BUFFERS:REOPEN_CLOSED_BUFFER_DIR"; do
  IFS=: read -r lib dir var <<< "$pair"
  if [ ! -f "$dir/$lib.el" ]; then
    echo "$lib not found at $dir: set $var" >&2
    exit 2
  fi
done
ENGINE="$(cd "$ENGINE" && pwd)"
CAPTURE="$(cd "$CAPTURE" && pwd)"
BUFFERS="$(cd "$BUFFERS" && pwd)"
export TERRA_EMACS_DIR="$ENGINE" TERRA_EMACS_CAPTURE_DIR="$CAPTURE" REOPEN_CLOSED_BUFFER_DIR="$BUFFERS"
PKGS="${TERRA_EMACS_TEST_PACKAGES:-/opt/emacs-test-packages}"
LP=(-L "$PKG_DIR" -L "$ENGINE" -L "$CAPTURE")
IFS=: read -r -a EXTRA <<< "${TERRA_EMACS_TEST_LOAD_PATH:-}"
if [ -z "${TERRA_EMACS_TEST_LOAD_PATH:-}" ] && [ ! -d "$PKGS" ]; then
  # Neither given: the copies the user's own Emacs installed, if any
  # (package.el's elpa, straight's build directories; Doom keeps those
  # under ~/.config/emacs/.local).
  shopt -s nullglob
  for d in "$HOME"/.emacs.d/elpa/{compat,eat,persp-mode}-[0-9]* \
           "$HOME"/.emacs.d/straight/build*/{compat,eat,persp-mode} \
           "${XDG_CONFIG_HOME:-$HOME/.config}"/emacs/elpa/{compat,eat,persp-mode}-[0-9]* \
           "${XDG_CONFIG_HOME:-$HOME/.config}"/emacs/.local/straight/build-*/{compat,eat,persp-mode}; do
    EXTRA+=("$d")
  done
  shopt -u nullglob
fi
for d in "$PKGS/eat-0.9.4" "$PKGS/external/pkg-persp-mode" ${EXTRA[@]+"${EXTRA[@]}"}; do
  if [ -n "$d" ] && [ -d "$d" ]; then LP+=(-L "$d"); fi
done

OUT="$(mktemp -d)"
trap 'trash "$OUT" 2> /dev/null || mv "$OUT" "${TMPDIR:-/tmp}/.reopen-closed-workspace-trash.$$"' EXIT
cp "$PKG_DIR"/reopen-closed-workspace*.el "$OUT"/
"$EMACS_BIN" -Q --batch -L "$OUT" "${LP[@]:2}" \
  --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile "$OUT"/reopen-closed-workspace*.el

if [ $# -eq 0 ]; then
  set -- $(cd "$TEST_DIR" && ls test-*.el | sed 's/\.el$//')
fi
RC=0
for suite in "$@"; do
  echo "== $suite"
  if ! "$EMACS_BIN" -Q --batch "${LP[@]}" -l "$TEST_DIR/$suite.el" \
    -f ert-run-tests-batch-and-exit; then
    echo "FAIL: $suite"
    RC=1
  fi
done
exit $RC
