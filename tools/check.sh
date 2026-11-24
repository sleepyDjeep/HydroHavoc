#!/usr/bin/env bash
# The local and CI gate: imports the project and parses every GDScript with a real Godot
# binary, then runs the headless tests and, where a display exists, the rendered silhouette
# check.
#
#   GODOT=/path/to/godot ./tools/check.sh
#   MEASURE_PROPS=0 GODOT=... ./tools/check.sh   # skip the windowed step on a desktop
#
# Exits non-zero if any step fails. Headless runs print a SKIP for the windowed step rather
# than failing, so the same script works in CI and on a developer machine.

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
done < <(find "$ROOT/scripts" "$ROOT/tests" "$ROOT/tools" -name '*.gd' | sort)

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

echo "== prop sizes =="
# Headless, so a sizing regression fails here rather than waiting for someone to run the
# windowed silhouette harness in tests/measure_props.gd.
if ! "$GODOT" --headless --path "$ROOT" --script "res://tests/prop_size.gd"; then
	echo "FAIL: prop sizes moved away from the baseline." >&2
	exit 1
fi

echo "OK: prop sizes match the baseline."

echo "== prop silhouettes =="
# The rendered check needs a real framebuffer, so it runs only where a display exists: CI
# stays green and headless, while a developer machine measures the actual pixels instead of
# relying on someone remembering to run the harness by hand. MEASURE_PROPS=0 skips it
# (fast iteration), MEASURE_PROPS=1 forces it.
windowed=0
case "${OS:-}:$(uname -s)" in
	*Windows_NT*|MINGW*|MSYS*|CYGWIN*) windowed=1 ;;
esac
if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
	windowed=1
fi
case "${MEASURE_PROPS:-}" in
	0) windowed=0 ;;
	1) windowed=1 ;;
esac

if [ "$windowed" -eq 0 ]; then
	echo "SKIP prop silhouettes: no display available, so no pixels can be read (expected on headless CI)."
	echo "     Run it where a window can open: \"\$GODOT\" --path \"$ROOT\" --script res://tests/measure_props.gd"
else
	echo "rendering four props at 1280x720; this takes a minute."
	if ! "$GODOT" --path "$ROOT" --script "res://tests/measure_props.gd"; then
		echo "FAIL: rendered prop silhouettes moved away from the baseline (see .verify/*.png)." >&2
		echo "      If no window could actually open here, rerun with MEASURE_PROPS=0." >&2
		exit 1
	fi
	echo "OK: rendered prop silhouettes match the baseline."
fi

echo "all checks passed."
