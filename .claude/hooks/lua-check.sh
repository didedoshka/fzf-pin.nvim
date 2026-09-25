#!/usr/bin/env bash
# PostToolUse hook: after any Lua edit in this repo, run tests/run.sh, then
# liter's suite -- liter drives build() as a consumer, so its spec is the
# integration test for this plugin's surface. Measured: the esc/ctrl-x reload
# refactor changed build().entries to a function and broke liter's spec while
# this repo's own suite stayed green.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

file="$(jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null)"
[[ "$file" == *.lua ]] || exit 0        # not lua -- nothing to do
[[ "$file" == "$repo"/* ]] || exit 0    # not this repo's lua

fail() {
    {
        echo "$1"
        sed -e 's/\x1b\[[0-9;]*m//g' -e 's/\r/\n/g' <<<"$2" \
            | grep -vE '^\s*$|^\s*Initializing|^\s*[>=]+ *[0-9]+/[0-9]+'
    } >&2
    exit 2
}

out="$("$repo/tests/run.sh" 2>&1)" || fail "fzf-pin tests/run.sh failed:" "$out"

liter="$HOME/personal/liter.nvim"
out="$("$liter/tests/run.sh" 2>&1)" \
    || fail "liter's suite failed -- it consumes build() and is the integration test for this edit:" "$out"
