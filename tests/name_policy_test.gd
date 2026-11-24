extends SceneTree

## Checks the donor-name display policy in both directions: evasions must be blocked and
## ordinary viewer names must survive untouched. Run by tools/check.sh.

const FIXTURE_PATH: String = "user://name_policy_test_blocklist.txt"

var checks: int = 0
var failures: int = 0

func _initialize() -> void:
	_run()

func _ok(condition: bool, label: String, detail: String = "") -> void:
	checks += 1
	if condition:
		return
	failures += 1
	print("FAIL " + label + ("" if detail.is_empty() else "  (" + detail + ")"))

func _run() -> void:
	# Suspend once so this runs after the tree is up; quit() issued from _initialize()
	# is ignored and the process hangs instead of exiting.
	await process_frame

	# Fixture blocklist: one substring entry, one whole-name entry.
	var file: FileAccess = FileAccess.open(FIXTURE_PATH, FileAccess.WRITE)
	file.store_string("# fixture\n*badword*\nexactterm\n")
	file.close()

	NamePolicy.load_blocklist(FIXTURE_PATH)
	var fallback: String = NamePolicy.FALLBACK_NAME

	# --- evasions must all be blocked -------------------------------------------------
	for evasion in ["badword", "BadWord", "bad_word", "b.a.d.w.o.r.d", "bad w o r d",
			"b4dw0rd", "baaadwooord", "xxXbadwordXxx"]:
		_ok(NamePolicy.display_name(evasion) == fallback, "blocked: " + evasion,
			"got '" + NamePolicy.display_name(evasion) + "'")

	# --- whole-name entries must not match longer names -------------------------------
	_ok(NamePolicy.display_name("exactterm") == fallback, "blocked: whole-name entry")
	_ok(NamePolicy.display_name("exactterm_fan") == "exactterm_fan",
		"whole-name entry does not match a longer name",
		"got '" + NamePolicy.display_name("exactterm_fan") + "'")

	# --- ordinary names must pass through unchanged -----------------------------------
	for innocent in ["viewer_42", "duck_fan", "ChadBits", "classy_cassandra"]:
		_ok(NamePolicy.display_name(innocent) == innocent, "allowed: " + innocent,
			"got '" + NamePolicy.display_name(innocent) + "'")

	# --- length clamp -----------------------------------------------------------------
	var long_name: String = "averyveryverylongviewername"
	var clamped: String = NamePolicy.display_name(long_name)
	_ok(clamped.length() <= NamePolicy.MAX_DISPLAY_CHARS, "long name is clamped",
		"%d chars" % clamped.length())
	_ok(clamped.ends_with("..."), "clamped name is marked", "'" + clamped + "'")
	_ok(clamped.begins_with("avery"), "clamped name keeps the start", "'" + clamped + "'")

	# --- control characters cannot reflow or break the plate ---------------------------
	var multiline: String = NamePolicy.display_name("bad\nname")
	_ok(multiline.find("\n") == -1, "newlines are stripped",
		"'" + multiline + "'")
	var control: String = NamePolicy.display_name("bad" + String.chr(7) + "name")
	_ok(control == "bad name" or control == "badname", "control characters are stripped",
		"'" + control + "'")
	var bidi: String = NamePolicy.display_name("abc" + String.chr(0x202E) + "def")
	_ok(bidi == "abcdef", "bidi overrides are stripped", "'" + bidi + "'")
	_ok(NamePolicy.display_name("   ") == fallback, "blank name falls back")
	_ok(NamePolicy.display_name("") == fallback, "empty name falls back")

	# --- shipped defaults catch the obvious case --------------------------------------
	NamePolicy.load_blocklist(NamePolicy.BLOCKLIST_PATH)
	_ok(NamePolicy.display_name("n1gger") == fallback, "default list blocks a slur",
		"got '" + NamePolicy.display_name("n1gger") + "'")
	_ok(NamePolicy.display_name("duck_fan") == "duck_fan",
		"default list leaves ordinary names alone",
		"got '" + NamePolicy.display_name("duck_fan") + "'")

	# --- the nameplate actually uses it ------------------------------------------------
	var prop: FloatingProp = FloatingProp.new()
	prop.setup(null, FloatingProp.PropClass.RUBBER_DUCK, "n1gger", "Rose", 10)
	_ok(prop.donor_name == fallback, "prop stores the filtered name",
		"got '" + prop.donor_name + "'")
	var plate: String = prop.call("_format_nameplate")
	_ok(plate.find("nigger") == -1 and plate.find("n1gger") == -1,
		"nameplate text carries no slur", "'" + plate.replace("\n", "\\n") + "'")
	prop.free()

	DirAccess.remove_absolute(ProjectSettings.globalize_path(FIXTURE_PATH))
	NamePolicy.load_blocklist()

	print("--- %d checks, %d failures ---" % [checks, failures])
	quit(1 if failures > 0 else 0)
