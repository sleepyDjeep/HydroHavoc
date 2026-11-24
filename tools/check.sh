#!/usr/bin/env bash
# Imports the project and parses every GDScript with a real Godot binary.
#
#   GODOT=/path/to/godot ./tools/check.sh
#
# Exits non-zero if the import fails or any script fails to parse.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GODOT="${GODOT:-}"
if [ -z "$GODOT" ]; then
	for candidate in godot godot4 Godot; do
		if command -v "$candidate" >/dev/null 2>&1; then
			GODOT="$candidate"
			break
		fi
	done
fi

if [ -z "$GODOT" ]; then
	echo "error: no Godot binary found. Set GODOT=/path/to/godot (4.7.x)." >&2
	exit 2
fi

if ! command -v "$GODOT" >/dev/null 2>&1 && [ ! -x "$GODOT" ]; then
	echo "error: GODOT='$GODOT' is not executable." >&2
	exit 2
fi

echo "engine: $("$GODOT" --version 2>/dev/null | tail -n 1)"
echo "project: $ROOT"

echo "== import =="
if ! "$GODOT" --headless --path "$ROOT" --import; then
	echo "FAIL: project import did not complete." >&2
	exit 1
fi

echo "== parse =="
total=0
failed=0

while IFS= read -r file; do
	rel="${file#"$ROOT"/}"
	total=$((total + 1))
	if "$GODOT" --headless --path "$ROOT" --check-only --script "res://$rel" >/dev/null 2>&1; then
		echo "PASS $rel"
	else
		echo "FAIL $rel"
		"$GODOT" --headless --path "$ROOT" --check-only --script "res://$rel" 2>&1 | sed 's/^/    /'
		failed=$((failed + 1))
	fi
done < <(find "$ROOT/scripts" "$ROOT/tests" -name '*.gd' | sort)

if [ "$total" -eq 0 ]; then
	echo "FAIL: no scripts found under $ROOT/scripts." >&2
	exit 1
fi

if [ "$failed" -ne 0 ]; then
	echo "FAIL: $failed of $total scripts did not parse." >&2
	exit 1
fi

echo "OK: $total scripts parsed."

echo "== sim invariants =="
if ! "$GODOT" --headless --path "$ROOT" --script "res://tests/sim_invariants.gd"; then
	echo "FAIL: simulation invariants broke." >&2
	exit 1
fi

echo "OK: simulation invariants hold."

echo "== donor name policy =="
if ! "$GODOT" --headless --path "$ROOT" --script "res://tests/name_policy_test.gd"; then
	echo "FAIL: donor name policy broke." >&2
	exit 1
fi

echo "OK: donor name policy holds."
