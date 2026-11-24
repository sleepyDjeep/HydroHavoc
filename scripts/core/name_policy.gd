class_name NamePolicy
extends RefCounted

## Display policy for donor names that reach the screen during a live stream: prop
## nameplates, gift alerts and the VIP throne all take their text from here.
##
## Two layers, neither of which needs a rebuild to change:
##
##   1. a hard length clamp plus whitespace/control-character stripping, so a name can
##      never reflow a nameplate, inject a second line, or reorder itself with bidi
##      overrides;
##   2. a blocklist read from user://name_blocklist.txt, seeded with a default list on
##      first run and left as plain text for the streamer to edit.
##
## A blocked or empty name is replaced with FALLBACK_NAME, so nothing that trips the
## filter reaches the frame. Matching is deliberately fuzzy: case, punctuation, spacing,
## repeated letters and common leet substitutions are folded before comparing, because
## "n i g g 3 r" is the same slur as "nigger" to a viewer.

const MAX_DISPLAY_CHARS: int = 16
const FALLBACK_NAME: String = "Viewer"
const BLOCKLIST_PATH: String = "user://name_blocklist.txt"
const MIN_SUBSTRING_LENGTH: int = 3

const DEFAULT_BLOCKLIST: String = """# HydroHavoc donor-name blocklist
# One entry per line, plain text; lines starting with # are ignored.
#
# Entries are matched after lowercasing, folding leet substitutions (0 1 3 4 5 7 8 @ $),
# dropping punctuation and spaces, and squeezing repeated letters.
#
#   *term*   matches anywhere in a name   (used below for the strong slurs)
#   term     matches only the whole name  (use for short or ambiguous strings)
#
# Substring entries can catch innocent words ("grapefruit" vs "*rape*"); switch such an
# entry to a bare word if that matters to your community. A matched name is shown as
# "Viewer" instead of being masked.
#
# Edit this file while the stream is offline, then restart the game. Deleting the file
# rewrites these defaults.
*nigg*
*fag*
*kike*
*chink*
*tranny*
*retard*
*nazi*
*hitler*
*1488*
*rape*
"""

static var _exact: Array[String] = []
static var _substrings: Array[String] = []
static var _loaded: bool = false

## Name to put on screen for `raw`: clamped, cleaned, and anonymised if it is blocked.
static func display_name(raw: String) -> String:
	var clean: String = sanitize(raw)
	if clean.is_empty():
		return FALLBACK_NAME
	if is_blocked(clean):
		# Never echo the name itself into logs: that would write the slur to disk.
		print("[NamePolicy] blocked donor name replaced with fallback")
		return FALLBACK_NAME
	return clean

## Clamp and clean a name without applying the blocklist.
static func sanitize(raw: String) -> String:
	var out: String = ""
	var last_was_space: bool = false

	for i in range(raw.length()):
		var code: int = raw.unicode_at(i)
		if code == 9 or code == 10 or code == 13 or code == 32:
			if not out.is_empty() and not last_was_space:
				out += " "
				last_was_space = true
			continue
		if code < 32 or code == 127:
			continue # control characters
		if code == 0xFEFF or (code >= 0x200B and code <= 0x200F) \
				or (code >= 0x202A and code <= 0x202E):
			continue # zero-width and bidi overrides
		out += String.chr(code)
		last_was_space = false

	out = out.strip_edges()
	if out.length() > MAX_DISPLAY_CHARS:
		out = out.substr(0, MAX_DISPLAY_CHARS - 3).strip_edges() + "..."
	return out

static func is_blocked(raw: String) -> bool:
	_ensure_loaded()
	var squashed: String = _squash(raw)
	if squashed.is_empty():
		return false

	if _exact.has(squashed):
		return true
	for term in _substrings:
		if term.length() >= MIN_SUBSTRING_LENGTH and squashed.contains(term):
			return true
	return false

## Re-read the blocklist. Called lazily on first use; exposed so a streamer can hot
## reload after editing the file, and so tests can point at a fixture.
##
## Named load_blocklist on purpose: a static member called `reload` resolves to
## Script.reload() instead, which re-enters script loading and hangs the process.
static func load_blocklist(path: String = BLOCKLIST_PATH) -> void:
	_exact.clear()
	_substrings.clear()

	for raw_term in _read_terms(path):
		var term: String = raw_term.strip_edges()
		if term.is_empty():
			continue
		var substring: bool = term.begins_with("*") or term.ends_with("*")
		var squashed: String = _squash(term.replace("*", ""))
		if squashed.is_empty():
			continue
		if substring:
			_substrings.append(squashed)
		else:
			_exact.append(squashed)

	_loaded = true

static func _ensure_loaded() -> void:
	if not _loaded:
		load_blocklist()

static func _read_terms(path: String) -> PackedStringArray:
	if not FileAccess.file_exists(path):
		var created: FileAccess = FileAccess.open(path, FileAccess.WRITE)
		if created:
			created.store_string(DEFAULT_BLOCKLIST)
			created.close()

	# Read the whole file rather than looping on eof_reached(): a file ending in a newline
	# can leave that loop spinning forever on get_line().
	var text: String = ""
	if FileAccess.file_exists(path):
		var file: FileAccess = FileAccess.open(path, FileAccess.READ)
		if file:
			text = file.get_as_text()
			file.close()

	var terms: PackedStringArray = PackedStringArray()
	for raw_line in text.split("\n"):
		var line: String = raw_line.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		terms.append(line)

	# Unreadable or emptied file: fall back to the built-in list rather than disabling
	# the filter by accident.
	if terms.is_empty():
		for line in DEFAULT_BLOCKLIST.split("\n"):
			var fallback: String = line.strip_edges()
			if fallback.is_empty() or fallback.begins_with("#"):
				continue
			terms.append(fallback)
	return terms

## Lowercase, fold leet substitutions, keep only letters and digits, and squeeze runs of
## the same character. "N1ggg3r!" and "n.i.g.g.e.r" both collapse to "niger".
static func _squash(raw: String) -> String:
	var out: String = ""
	var last: String = ""

	for i in range(raw.length()):
		var c: String = raw.substr(i, 1).to_lower()
		match c:
			"0":
				c = "o"
			"1":
				c = "i"
			"3":
				c = "e"
			"4", "@":
				c = "a"
			"5", "$":
				c = "s"
			"7":
				c = "t"
			"8":
				c = "b"
		var code: int = c.unicode_at(0)
		var is_alnum: bool = (code >= 97 and code <= 122) or (code >= 48 and code <= 57)
		if not is_alnum:
			continue
		if c == last:
			continue
		out += c
		last = c

	return out
