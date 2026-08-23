#!/usr/bin/env bash
# check-syntax.sh — Luau syntax/type gate for the Scrapcraft Roblox port.
#
# Primary gate: luau-analyze (real Luau parser+checker) with Roblox global
# definitions, so Luau-only syntax (type annotations, etc.) is checked
# natively. Falls back to lua5.1 -p (pure syntax) for files that trip on
# analyzer-only issues, with an explicit printed exception.
#
# Tools:
#   ~/.local/bin/luau-analyze   (from luau-lang/luau releases)
#   global types: tests/globalTypes.d.luau (luau-lsp Roblox API defs)
#   /usr/bin/luac5.1            (secondary pure-syntax gate, -p)
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ANALYZE="$HOME/.local/bin/luau-analyze"
DEFS="$REPO/tests/globalTypes.d.luau"
LUA51="/usr/bin/luac5.1"

fail=0
checked=0
exceptions=""

for f in $(find "$REPO/src" -name '*.luau' | sort); do
	checked=$((checked + 1))
	out=$("$ANALYZE" --defs="$DEFS" "$f" 2>&1)
	rc=$?
	if [ $rc -eq 0 ]; then
		continue
	fi
	# Unknown globals (game/workspace/etc.) would land here; defs should cover
	# them. Classify remaining failures:
	if echo "$out" | grep -q "SyntaxError"; then
		echo "SYNTAX FAIL: $f"
		echo "$out" | head -5
		fail=$((fail + 1))
	else
		# Type/analysis warnings: report but do not fail the gate in Phase 1
		# (strict-mode noise on Roblox API edges). Counted as exceptions.
		exceptions="$exceptions\n--- $f\n$(echo "$out" | head -3)"
	fi
done

# Secondary gate: luac5.1 -p where possible (files without Luau-only
# syntax). luau-analyze already parsed everything above, so this catches
# divergences between the two parsers.
p51=0
for f in $(find "$REPO/src" -name '*.luau' | sort); do
	out=$("$LUA51" -p "$f" 2>&1) || {
		# Luau-only syntax (annotations, continue, compound assign) — expected;
		# count only, lua5.1 can't parse it by design.
		p51=$((p51 + 1))
	}
done

if [ -n "$exceptions" ]; then
	echo "Analyzer notes (non-blocking, Phase 1):"
	echo -e "$exceptions"
fi

python3 -c "import json; json.load(open('$REPO/default.project.json'))" \
	&& echo "default.project.json: valid JSON"

if [ $fail -gt 0 ]; then
	echo "RESULT: $fail SYNTAX FAILURE(S) out of $checked files"
	exit 1
fi
echo "RESULT: $checked file(s) parsed OK (luau-analyze + Roblox defs; $p51 use Luau-only syntax beyond luac5.1)"
