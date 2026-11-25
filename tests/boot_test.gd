extends SceneTree

## Boot test that runs headless: the scene comes up, the three abilities are on the keys the
## HUD promises, pressing those keys actually starts their cooldowns, the top-bar meters stay
## out of the score box, and no runtime string has drifted off ASCII.
##
## The windowed version of this lived in .verify/ and was lost, which left the input bindings
## and the HUD layout with no coverage at all: the rest of the gate tests geometry, the fluid
## sim and prop sizes, none of which notices a rebound key or a meter sliding under the score.
##
## Everything here is an invariant, so there is no baseline to regenerate: layout is measured in
## a 1920x1080 SubViewport (the headless root viewport is not 16:9 there, so the HUD would lay
## out against the wrong shape), and the abilities are pressed through the real InputMap so a
## rebind shows up here rather than in someone's stream.

const DT: float = 1.0 / 30.0
const VIEW: Vector2i = Vector2i(1920, 1080)
const HUD_SCENE: String = "res://scenes/ui/hud.tscn"
const ABILITY_KEYS: Array[int] = [KEY_1, KEY_2, KEY_3]
const RECHARGING_TITLE: String = "ABILITY RECHARGING"

var checks: int = 0
var failures: int = 0

func _initialize() -> void:
	_run()

func _ok(condition: bool, label: String, detail: String = "") -> void:
	checks += 1
	if not condition:
		failures += 1
	print(("PASS " if condition else "FAIL ") + label + ("" if detail.is_empty() else "  " + detail))

## One game tick, with the earthquake path muted: an earthquake mid-test would replace the alert
## this test reads, and the drain threshold has its own coverage in tests/sim_invariants.gd.
func _tick(main: GameManager) -> void:
	main._process(DT)
	main.sim.total_spilled_water = 0.0

## Press an ability the way the game reads it. Input.action_press marks the action pressed in
## this frame, so is_action_just_pressed() inside the tick below sees it — the same path a
## keypress takes, unlike calling _on_ability_triggered() directly.
func _press(main: GameManager, index: int) -> void:
	var action: String = "ability_%d" % (index + 1)
	Input.action_press(action)
	_tick(main)
	Input.action_release(action)

func _is_ascii(text: String) -> bool:
	for i in range(text.length()):
		var code: int = text.unicode_at(i)
		if code == 9 or code == 10 or code == 13:
			continue
		if code < 32 or code > 126:
			return false
	return true

func _ascii_offenders(node: Node, out: Array) -> void:
	var text: String = ""
	if node is Label:
		text = (node as Label).text
	elif node is Button:
		text = (node as Button).text
	elif node is Label3D:
		text = (node as Label3D).text
	elif node is RichTextLabel:
		text = (node as RichTextLabel).text
	if not text.is_empty() and not _is_ascii(text):
		out.append("%s: %s" % [node.get_path(), text])
	for child in node.get_children():
		_ascii_offenders(child, out)

func _ability_buttons(hud: GameHUD) -> Array:
	return [hud.btn_ability_1, hud.btn_ability_2, hud.btn_ability_3]

func _run() -> void:
	# Suspend once: quit() from _initialize() without an await hangs instead of exiting.
	await process_frame
	seed(0) # the boot spawns the queue and a first piece from the global RNG

	var main: GameManager = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.set_process(false)
	# The toast timer fades the alert text; this test reads that text.
	main.hud.set_process(false)

	# --- the bindings the HUD advertises ------------------------------------------------
	for i in range(3):
		var action: String = "ability_%d" % (i + 1)
		var bound: bool = InputMap.has_action(action)
		_ok(bound, action + " exists in the input map",
			"" if bound else "project.godot has no such action")
		if not bound:
			continue
		var keycode: int = -1
		for event in InputMap.action_get_events(action):
			if event is InputEventKey:
				keycode = (event as InputEventKey).keycode
				break
		_ok(keycode == ABILITY_KEYS[i],
			action + " is bound to " + OS.get_keycode_string(ABILITY_KEYS[i]),
			"keycode " + (OS.get_keycode_string(keycode) if keycode >= 0 else "none"))

	# --- pressing each key starts its cooldown -----------------------------------------
	for i in range(3):
		var action: String = "ability_%d" % (i + 1)
		var full: float = GameManager.ABILITY_COOLDOWNS[i]
		_press(main, i)
		# _process handles input first and then ticks the cooldowns, so one tick is already gone.
		var left: float = main.ability_cooldowns[i]
		_ok(left > full - 2.0 * DT and left <= full,
			action + " starts its %.0f s cooldown" % full,
			"%.2f s left" % left)
		var buttons: Array = _ability_buttons(main.hud)
		var button: Button = buttons[i]
		_ok(button.disabled and button.text.contains("s)"),
			action + " greys out its HUD button",
			button.text)

	# --- a cooling ability does not re-fire --------------------------------------------
	for i in range(3):
		var action: String = "ability_%d" % (i + 1)
		var before: float = main.ability_cooldowns[i]
		_press(main, i)
		_ok(main.ability_cooldowns[i] <= before,
			action + " does not restart while cooling",
			"%.2f s -> %.2f s" % [before, main.ability_cooldowns[i]])
		_ok(main.hud.toast_title.text == RECHARGING_TITLE,
			action + " says it is recharging", main.hud.toast_title.text)

	# --- and fires again once the cooldown runs out -----------------------------------
	main.ability_cooldowns[0] = DT * 0.5
	_tick(main)
	_ok(main.ability_cooldowns[0] == 0.0, "a cooldown ticks down to ready",
		"%.3f s" % main.ability_cooldowns[0])
	var nudge: Button = _ability_buttons(main.hud)[0]
	_ok(not nudge.disabled and not nudge.text.contains("s)"),
		"the HUD button re-enables", nudge.text)
	_press(main, 0)
	_ok(main.ability_cooldowns[0] > GameManager.ABILITY_COOLDOWNS[0] - 2.0 * DT,
		"the same key fires again once ready", "%.2f s left" % main.ability_cooldowns[0])

	# --- the top bar, laid out at the shipping aspect ----------------------------------
	var view: SubViewport = SubViewport.new()
	view.size = VIEW
	view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	root.add_child(view)
	var hud: GameHUD = load(HUD_SCENE).instantiate()
	view.add_child(hud)
	for i in range(3):
		await process_frame

	var score_box: Control = hud.get_node("RootControl/TopBar/ScoreBox")
	var score_rect: Rect2 = score_box.get_global_rect()
	var water_rect: Rect2 = hud.water_vol_bar.get_global_rect()
	var drain_rect: Rect2 = hud.drain_bar.get_global_rect()

	_ok(water_rect.size.x > 0.0 and water_rect.size.y > 0.0, "water meter is laid out",
		"%.0fx%.0f px at (%.0f,%.0f)" % [water_rect.size.x, water_rect.size.y,
			water_rect.position.x, water_rect.position.y])
	_ok(drain_rect.size.x > 0.0 and drain_rect.size.y > 0.0, "drain meter is laid out",
		"%.0fx%.0f px at (%.0f,%.0f)" % [drain_rect.size.x, drain_rect.size.y,
			drain_rect.position.x, drain_rect.position.y])
	_ok(score_rect.size.x > 0.0 and score_rect.size.y > 0.0, "score box is laid out",
		"%.0fx%.0f px at (%.0f,%.0f)" % [score_rect.size.x, score_rect.size.y,
			score_rect.position.x, score_rect.position.y])
	_ok(not water_rect.intersects(score_rect), "water meter clears the score box",
		"meter ends x=%.0f, score starts x=%.0f" % [water_rect.end.x, score_rect.position.x])
	_ok(not drain_rect.intersects(score_rect), "drain meter clears the score box",
		"meter ends x=%.0f, score starts x=%.0f" % [drain_rect.end.x, score_rect.position.x])
	_ok(not water_rect.intersects(drain_rect), "water and drain meters do not overlap",
		"water ends x=%.0f, drain starts x=%.0f" % [water_rect.end.x, drain_rect.position.x])
	_ok(score_rect.end.x <= float(VIEW.x) + 0.5 and score_rect.position.x >= 0.0,
		"score box fits inside the frame",
		"x %.0f..%.0f of %d" % [score_rect.position.x, score_rect.end.x, VIEW.x])

	# --- no tofu in the strings the player reads --------------------------------------
	var offenders: Array = []
	_ascii_offenders(main, offenders)
	_ok(offenders.is_empty(), "no non-ASCII text in runtime strings",
		"" if offenders.is_empty() else ", ".join(offenders.slice(0, 4)))
	var alert_title: String = main.hud.toast_title.text
	var alert_subtitle: String = main.hud.toast_subtitle.text
	_ok(not alert_title.is_empty() and not alert_subtitle.is_empty()
			and _is_ascii(alert_title) and _is_ascii(alert_subtitle),
		"generated alert text is ASCII",
		"'%s' / '%s'" % [alert_title, alert_subtitle])

	print("--- %d checks, %d failures ---" % [checks, failures])
	quit(1 if failures > 0 else 0)
