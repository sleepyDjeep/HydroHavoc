extends SceneTree

## Windowed 720p silhouette check for the props and their nameplates, compared against the
## tracked baseline in tests/prop_silhouette_720p.json. "The duck did not move" is then a
## number in the repo rather than a claim in a chat log:
##
##   "$GODOT" --path . --script res://tests/measure_props.gd
##   "$GODOT" --path . --script res://tests/measure_props.gd -- --update-baseline
##
## tools/check.sh runs this whenever a display is present and prints a SKIP when it is not,
## so headless CI stays green while a desktop gate measures real pixels. It cannot run
## headless: the dummy rendering driver hangs on the SubViewport readback. Props sit fully
## inside the frame and the sim is stepped a fixed number of times, so two runs are
## comparable. PNGs land in .verify/ (gitignored).
##
## The water surface is hidden for the keyed captures. It is translucent and clips whatever sits
## below the waterline, and that waterline is not reproducible: the surface shader displaces
## vertices by TIME, and the level after the settle ticks depends on the stream events those
## ticks happen to roll (unseeded). Five captures of the mascot through water read 1644-1646
## px2 at a 1.71 m surface, while the same geometry read 1677 px2 at 2.21 m; the tracked
## baseline had 1522 from yet another level, 10% away with the silhouette unchanged. With the
## water hidden the number is the prop's own pixels and repeats exactly.
##
## The world is seeded for the same reason: the settle ticks drive the real game manager, and
## unseeded stream events move water around, which moves every prop by a few cm between
## launches. With the seed fixed and the water hidden, four consecutive runs measured the same
## four silhouettes to the pixel.

const VIEW: Vector2i = Vector2i(1280, 720)
const KEY: Color = Color(1.0, 0.0, 1.0)
const SETTLE_TICKS: int = 120
const DT: float = 1.0 / 30.0
const OUT_PATH: String = "user://prop_measure.txt"
const OUT_DIR: String = "res://.verify"
const BASELINE_PATH: String = "res://tests/prop_silhouette_720p.json"
## Measured edges move by about a pixel between runs (antialiasing), so the baseline is a
## band rather than an exact value.
const SIZE_TOLERANCE_PX: int = 2
## Area repeats to about a pixel with the water hidden; what still moves is where the prop sits
## on screen, because its height is taken from the water level and that differs by a few cm
## between runs (~2 px, ~2% of a silhouette). 5% therefore flags a real change in shape while
## leaving that positional wobble alone.
const AREA_TOLERANCE_PCT: float = 5.0

var checks: int = 0
var failures: int = 0
## Pixel comparisons that were reported but not counted because the run is on a different
## renderer/GPU/driver/MSAA/engine than the baseline recorded.
var softs: int = 0

func _initialize() -> void:
	_run()

func _ok(condition: bool, label: String, detail: String = "") -> void:
	checks += 1
	if not condition:
		failures += 1
	print(("PASS " if condition else "FAIL ") + label + ("" if detail.is_empty() else "  " + detail))

## Reported, never failed: the numbers are only comparable on the machine that recorded them.
func _soft(condition: bool, label: String, detail: String = "") -> void:
	softs += 1
	print(("SOFT-PASS " if condition else "SOFT-DIFF ") + label
		+ ("" if detail.is_empty() else "  " + detail))

func _check(strict: bool, condition: bool, label: String, detail: String = "") -> void:
	if strict:
		_ok(condition, label, detail)
	else:
		_soft(condition, label, detail)

## Rendered pixels are a property of the machine as well as of the props: another GPU, driver,
## MSAA level or engine build moves edges by more than the size tolerance without anything
## about a prop changing. Record what produced the baseline and only assert against it where
## that environment still holds.
func _environment() -> Dictionary:
	return {
		"engine": str(Engine.get_version_info().get("string", "unknown")),
		"renderer": "%s/%s" % [RenderingServer.get_current_rendering_method(),
			RenderingServer.get_current_rendering_driver_name()],
		"gpu": RenderingServer.get_video_adapter_name(),
		"gpu_vendor": RenderingServer.get_video_adapter_vendor(),
		"msaa": int(root.msaa_3d),
	}

func _describe_environment(env: Dictionary) -> String:
	if env.is_empty():
		return "not recorded"
	return "%s, %s, %s (%s), MSAA %d" % [env.get("engine", "?"), env.get("renderer", "?"),
		env.get("gpu", "?"), env.get("gpu_vendor", "?"), int(env.get("msaa", -1))]

## Empty string when the run matches the baseline's machine.
func _environment_mismatch(current: Dictionary, recorded: Dictionary) -> String:
	if recorded.is_empty():
		return "the baseline records no environment"
	var diffs: Array = []
	for key in ["engine", "renderer", "gpu", "gpu_vendor"]:
		if str(recorded.get(key, "?")) != str(current.get(key, "?")):
			diffs.append("%s: baseline %s, this run %s" % [key, str(recorded.get(key, "?")),
				str(current.get(key, "?"))])
	# JSON has no integers, so the recorded MSAA level reads back as a float; compare numbers.
	if int(recorded.get("msaa", -1)) != int(current.get("msaa", -2)):
		diffs.append("msaa: baseline %d, this run %d" % [int(recorded.get("msaa", -1)),
			int(current.get("msaa", -2))])
	return ", ".join(diffs)

## The baseline is about geometry, and plates are wider than the props they label. The
## keyed test would also pick up a warm-coloured plate (Rose ffb 1.0/0.4/0.6 passes it), so
## every plate is hidden while a silhouette is captured.
func _set_plates_visible(props: Array, state: bool) -> void:
	for prop in props:
		if is_instance_valid(prop) and prop.nameplate_label:
			prop.nameplate_label.visible = state

## Screen rectangle of a plate, in image pixels (the canvas is 1920x1080 and the window is
## 1280x720, so everything is scaled back down).
func _plate_rect(cam: Camera3D, prop: FloatingProp, canvas_scale: Vector2) -> Rect2:
	var plate: Vector2 = prop.nameplate_size_world() * prop.nameplate_scale
	var anchor: Vector3 = prop.nameplate_label.position
	var centre: Vector2 = cam.unproject_position(anchor) * canvas_scale
	var half_right: Vector3 = cam.global_transform.basis.x * plate.x * 0.5
	var w: float = (cam.unproject_position(anchor - half_right) * canvas_scale).distance_to(
		cam.unproject_position(anchor + half_right) * canvas_scale)
	# Measured against the camera plane, matching the layout: world up is foreshortened by
	# the camera pitch, so projecting it here would under-report the plate's height.
	var h: float = (cam.unproject_position(anchor + cam.global_transform.basis.y * plate.y)
		* canvas_scale).distance_to(centre)
	return Rect2(centre - Vector2(w, h) * 0.5, Vector2(w, h))

func _prop_rect(cam: Camera3D, prop: FloatingProp, canvas_scale: Vector2) -> Rect2:
	var box: AABB = prop.visual_box_world()
	var lo: Vector2 = Vector2(INF, INF)
	var hi: Vector2 = Vector2(-INF, -INF)
	for i in range(8):
		var corner: Vector3 = box.position + Vector3(
			box.size.x if (i & 1) else 0.0,
			box.size.y if (i & 2) else 0.0,
			box.size.z if (i & 4) else 0.0)
		var p: Vector2 = cam.unproject_position(corner) * canvas_scale
		lo = lo.min(p)
		hi = hi.max(p)
	return Rect2(lo, hi - lo)

## The mascot now plays its Idle clip, so its pose depends on how long the window has been open
## by the time a frame is captured: the same underlying geometry measured anywhere from 1603 to
## 1816 px2 at an identical 78x95 box before the pose was pinned. Seek each player to frame 0
## and pause it, so the silhouette is a property of the model rather than of start-up time.
func _pin_poses(node: Node) -> void:
	for child in node.get_children():
		if child is AnimationPlayer:
			var player: AnimationPlayer = child
			if not player.current_animation.is_empty():
				player.play(player.current_animation) # restart so the seek lands on frame 0
				player.seek(0.0, true)
				player.pause()
		else:
			_pin_poses(child)

func _players(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child is AnimationPlayer:
			out.append(child)
		_players(child, out)

func _meshes(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child is MeshInstance3D and child.mesh:
			out.append(child)
		_meshes(child, out)

## Reads the size from the image instead of assuming VIEW: a readback at a different
## resolution would map every sample to the wrong pixel and report a smeared silhouette.
func _key_area(img: Image) -> Dictionary:
	var w: int = img.get_width()
	var h: int = img.get_height()
	var mask: PackedByteArray = PackedByteArray()
	mask.resize(w * h)
	for y in range(h):
		for x in range(w):
			var c: Color = img.get_pixel(x, y)
			mask[y * w + x] = 1 if (c.r > 0.30 and c.b > 0.30 and c.g < 0.45 * c.r and c.g < 0.45 * c.b) else 0

	var min_x: int = w
	var min_y: int = h
	var max_x: int = -1
	var max_y: int = -1
	var area: int = 0
	for y in range(1, h - 1):
		for x in range(1, w - 1):
			if mask[y * w + x] == 0:
				continue
			if mask[(y - 1) * w + x] == 0 or mask[(y + 1) * w + x] == 0:
				continue
			if mask[y * w + (x - 1)] == 0 or mask[y * w + (x + 1)] == 0:
				continue
			area += 1
			min_x = mini(min_x, x)
			max_x = maxi(max_x, x)
			min_y = mini(min_y, y)
			max_y = maxi(max_y, y)

	if area == 0:
		return {"area": 0, "w": 0, "h": 0}
	return {"area": area, "w": max_x - min_x + 1, "h": max_y - min_y + 1}

## The window can still be settling right after it opens: a readback then is a partially
## updated frame, which shows up as keyed pixels scattered away from the prop (the first launch
## of a run measured 145x101 for a 59x53 duck, with the area barely changed). With the water
## and the plates hidden the keyed frame is static, so requiring two identical frames in a row
## waits that out and costs one frame.
func _settled_frame() -> Image:
	var prev: PackedByteArray = PackedByteArray()
	var img: Image = null
	for i in range(12):
		await process_frame
		img = root.get_viewport().get_texture().get_image()
		if img.get_size() != VIEW:
			prev = PackedByteArray()
			continue
		var data: PackedByteArray = img.get_data()
		if not prev.is_empty() and data == prev:
			return img
		prev = data
	push_error("viewport frame never settled at %s" % str(VIEW))
	return img

func _load_baseline() -> Dictionary:
	if not FileAccess.file_exists(BASELINE_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(BASELINE_PATH))
	return parsed if parsed is Dictionary else {}

func _compare_silhouette(label: String, sil: Dictionary, baseline: Dictionary, strict: bool) -> void:
	var recorded: Dictionary = baseline.get("props", {})
	var entry: Dictionary = recorded.get(label, {})
	if entry.is_empty():
		_ok(false, label + " has a baseline entry", "run once with -- --update-baseline")
		return
	var base_w: int = int(entry.get("w", 0))
	var base_h: int = int(entry.get("h", 0))
	_check(strict, absi(int(sil["w"]) - base_w) <= SIZE_TOLERANCE_PX
			and absi(int(sil["h"]) - base_h) <= SIZE_TOLERANCE_PX,
		label + " size matches the baseline",
		"%dx%d vs baseline %dx%d" % [sil["w"], sil["h"], base_w, base_h])
	var base_area: float = maxf(float(entry.get("area", 1)), 1.0)
	var delta_pct: float = absf(float(sil["area"]) - base_area) / base_area * 100.0
	_check(strict, delta_pct <= AREA_TOLERANCE_PCT, label + " silhouette area",
		"%d px2 vs baseline %d (%.1f%%)" % [sil["area"], int(base_area), delta_pct])

func _compare_line_height(line_px: int, baseline: Dictionary, strict: bool) -> void:
	var base_line: int = int(baseline.get("nameplate_line_px", 0))
	if base_line <= 0:
		_ok(false, "baseline has a nameplate line height", "run once with -- --update-baseline")
		return
	_check(strict, absi(line_px - base_line) <= SIZE_TOLERANCE_PX,
		"nameplate line height matches the baseline", "%d px vs baseline %d" % [line_px, base_line])

func _write_baseline(measured: Dictionary, line_px: int) -> void:
	var doc: Dictionary = {
		"view": "1280x720, default camera, 16:9",
		"tolerance": {"size_px": SIZE_TOLERANCE_PX, "area_percent": AREA_TOLERANCE_PCT},
		"nameplate_line_px": line_px,
		"environment": _environment(),
		"props": measured,
	}
	var file: FileAccess = FileAccess.open(BASELINE_PATH, FileAccess.WRITE)
	file.store_string(JSON.stringify(doc, "\t", true) + "\n")
	file.close()
	print("wrote baseline: " + BASELINE_PATH)

func _run() -> void:
	DisplayServer.window_set_size(VIEW)
	await process_frame

	var update_baseline: bool = OS.get_cmdline_user_args().has("--update-baseline")
	var baseline: Dictionary = _load_baseline()
	var measured: Dictionary = {}
	var measured_line_px: int = 0
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	# Unseeded randomness makes the settle ticks roll different stream events on every launch
	# (an earthquake shoves water around, gifts drop props into the lake), which moved the water
	# level by ~4 cm and therefore every prop's height: the mascot sat at 2.2068 in one run and
	# 2.2471 in the next, a 1-2 px screen shift that flipped silhouette edges all over its body
	# and swung its keyed area between 1603 and 1816 px2 at an identical bounding box. Pin the
	# global RNG before the scene is built so each run starts from the same world.
	seed(0)

	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	# Stream events run on their own real-time timer, so how many of them fire before the settle
	# ticks depends on how long the launch took. One landing in the first frame was enough to move
	# the water level by a centimetre (2.21 vs 2.22 m) with the RNG already seeded, which shifts
	# every prop and flipped the marginal huddle-plate assertion on roughly one run in four.
	# Off before the first frame elapses, not after.
	main.stream_events.set_process(false)
	await process_frame
	main.set_process(false) # the harness owns the clock

	var cam: Camera3D = main.get_node("CameraPivot/Camera3D")
	var pm: PropManager = main.get_node("Arena/PropManager")
	var water: MeshInstance3D = main.get_node("Arena/WaterMeshInstance")
	# Own the layout clock as well: left automatic, the manager re-lays the plates out on
	# every awaited frame while the labels stay where the harness last put them, so the
	# measurement would mix a fresh layout with stale label positions.
	pm.set_process(false)
	var sim: FluidSim = main.sim

	# Use the stock starter map rather than a flat bed: a flat map lets the lake drain
	# straight off the rim, which fills the drain meter and fires the earthquake mid-run.
	# unproject_position returns canvas coordinates (the project renders at 1920x1080 and
	# the window scales it), so convert to image pixels for cropping.
	var canvas_scale: Vector2 = Vector2(VIEW) / root.get_viewport().get_visible_rect().size

	var specs: Array = [
		[FloatingProp.PropClass.RUBBER_DUCK, "Rubber Duck", "duck", Vector3(-2.0, 3.0, -2.0)],
		[FloatingProp.PropClass.GIFT_CRATE, "Gift Crate", "crate", Vector3(2.0, 3.0, -2.0)],
		[FloatingProp.PropClass.HEAVY_ANCHOR, "Heavy Anchor", "anchor", Vector3(-2.0, 3.0, 1.5)],
		[FloatingProp.PropClass.STREAMER_MASCOT, "Streamer Mascot", "mascot", Vector3(2.0, 3.0, 1.5)],
	]

	var props: Array = []
	var half: float = float(FluidSim.GRID_SIZE) * 0.5
	# The tiers game_manager actually spawns, so the colour-coded plates are exercised.
	var tiers: Array = ["Rose", "Rose", "Lion", "Galaxy"]
	var i_spec: int = 0
	for spec in specs:
		var prop: FloatingProp = pm.spawn_prop(spec[0], spec[2] + "_fan", tiers[i_spec], 10, spec[3])
		i_spec += 1
		props.append(prop)
		prop.set_process(false)
		var gx: int = clampi(int(floor(spec[3].x + half)), 0, FluidSim.GRID_SIZE - 1)
		var gy: int = clampi(int(floor(spec[3].z + half)), 0, FluidSim.GRID_SIZE - 1)
		for dy in range(-3, 4):
			for dx in range(-3, 4):
				if sim.get_water(gx + dx, gy + dy) <= 0.0:
					sim.add_water(gx + dx, gy + dy, 1.2)
	main.call("rebuild_water", true)

	# Fixed number of sim steps: no dependence on real frame timing, so two runs agree.
	for i in range(SETTLE_TICKS):
		main.call("_process", DT)

	# Splash rings and steam puffs tween in real time, so a capture can land while one still
	# covers a prop and knocks holes in its keyed silhouette (30% area swings on the crate).
	# They are PropManager children rather than props, so drop them here.
	for child in pm.get_children():
		if child is MeshInstance3D:
			child.queue_free()
	await process_frame

	# The mascot's Idle clip is the point of the model, so check it is actually running before
	# pinning it: a prop whose animation never starts would sail through a "pose is pinned" test.
	var mascot_players: Array = []
	for prop in props:
		if prop.prop_class == FloatingProp.PropClass.STREAMER_MASCOT:
			_players(prop, mascot_players)
	_ok(not mascot_players.is_empty(), "the mascot has an AnimationPlayer",
		"%d player(s)" % mascot_players.size())
	for player in mascot_players:
		_ok(player.current_animation == "Idle", "the mascot is playing Idle", player.current_animation)

	# Freeze every animated prop at the first frame of whatever it is playing (the mascot's Idle)
	# before any silhouette is captured.
	for prop in props:
		_pin_poses(prop)
	for player in mascot_players:
		_ok(not player.is_playing() and player.current_animation_position == 0.0,
			"the mascot's pose is pinned at frame 0",
			"%s at %.3f s, playing %s" % [player.current_animation,
				player.current_animation_position, player.is_playing()])

	for i in range(props.size()):
		var spec: Array = specs[i]
		var prop: FloatingProp = props[i]
		var surface: float = sim.get_water_height_at_world_pos(spec[3].x, spec[3].z)
		var depth: float = sim.get_water_depth_at_world_pos(spec[3].x, spec[3].z)
		var y: float = surface
		if spec[0] == FloatingProp.PropClass.HEAVY_ANCHOR:
			y = surface - depth + 0.25
		prop.position = Vector3(spec[3].x, y, spec[3].z)
		if prop.has_method("_track_nameplate"):
			prop.call("_track_nameplate")
		else:
			prop.call("_place_nameplate_top_level")

	# Pin the camera: the shake handler runs on every manual _process and uses an unseeded
	# RNG, which otherwise shifts the whole frame between runs.
	main.screen_shake_intensity = 0.0
	cam.position = Vector3.ZERO
	print("camera at %s, shake %.4f" % [cam.global_position, main.screen_shake_intensity])

	var key_mat: StandardMaterial3D = StandardMaterial3D.new()
	key_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	key_mat.albedo_color = KEY

	var lines: PackedStringArray = PackedStringArray()
	var env: Dictionary = _environment()
	var env_diff: String = _environment_mismatch(env, baseline.get("environment", {}))
	# Strict only where the pixels are comparable. Everything geometric below (in frame, plate
	# layout, legibility, tier colour) stays strict everywhere, because it does not depend on
	# the renderer.
	var strict: bool = update_baseline or env_diff.is_empty()
	if update_baseline:
		print("--- silhouette at %dx%d, %d settle ticks, recording baseline for %s ---"
			% [VIEW.x, VIEW.y, SETTLE_TICKS, _describe_environment(env)])
	elif strict:
		print("--- silhouette at %dx%d, %d settle ticks (%s) ---"
			% [VIEW.x, VIEW.y, SETTLE_TICKS, _describe_environment(env)])
	else:
		print("--- SOFT COMPARISON: this run is not the machine that recorded the baseline ---")
		print("    baseline: %s" % _describe_environment(baseline.get("environment", {})))
		print("    this run: %s" % _describe_environment(env))
		print("    differs:  %s" % env_diff)
		print("    pixel numbers are reported as SOFT-PASS/SOFT-DIFF and do not fail this run;")
		print("    re-record on this machine only if its silhouettes are the ones you ship.")
	# Off for the whole keyed section: the surface would clip each prop at a waterline that is
	# not reproducible run to run (see the header). Restored before the clean captures below.
	water.visible = false
	for i in range(props.size()):
		var prop: FloatingProp = props[i]
		var spec: Array = specs[i]
		var center: Vector2 = cam.unproject_position(prop.global_position) * canvas_scale
		_ok(center.x > 60.0 and center.x < VIEW.x - 60.0 and center.y > 60.0 and center.y < 600.0,
			spec[1] + " fully in frame", "screen px (%.0f,%.0f)" % [center.x, center.y])

		var meshes: Array = []
		_meshes(prop, meshes)
		var originals: Dictionary = {}
		for mi in meshes:
			originals[mi] = mi.material_override
			mi.material_override = key_mat
		_set_plates_visible(props, false)
		var frame: Image = await _settled_frame()
		_set_plates_visible(props, true)
		for mi in meshes:
			mi.material_override = originals[mi]

		var sil: Dictionary = _key_area(frame)
		print("%-14s %2d x %2d px, %5d area, y=%.2f, screen=(%.0f,%.0f)" %
			[spec[1], sil["w"], sil["h"], sil["area"], prop.position.y, center.x, center.y])
		lines.append("%s w=%d h=%d area=%d" % [spec[1], sil["w"], sil["h"], sil["area"]])
		if update_baseline:
			measured[spec[1]] = {"w": sil["w"], "h": sil["h"], "area": sil["area"]}
		else:
			_compare_silhouette(spec[1], sil, baseline, strict)

		var line_m: float = float(prop.nameplate_label.font_size) * prop.nameplate_label.pixel_size
		var a: Vector2 = cam.unproject_position(prop.nameplate_label.position)
		var b: Vector2 = cam.unproject_position(prop.nameplate_label.position + Vector3(0, line_m, 0))
		measured_line_px = int(round((b - a).length()))
		_ok(measured_line_px >= 11, spec[1] + " plate legible", "%d px line" % measured_line_px)

	water.visible = true
	for f in range(3):
		await process_frame
	var clean: Image = root.get_viewport().get_texture().get_image()
	clean.save_png(OUT_DIR + "/props_720p.png")

	# 8x crops so the anchor ring can be judged at render size.
	for i in range(props.size()):
		var prop: FloatingProp = props[i]
		var spec: Array = specs[i]
		var c: Vector2 = cam.unproject_position(prop.global_position) * canvas_scale
		var rect: Rect2i = Rect2i(int(c.x) - 40, int(c.y) - 55, 80, 80)
		rect = rect.intersection(Rect2i(Vector2i(4, 4), VIEW - Vector2i(8, 8)))
		if rect.size.x <= 0 or rect.size.y <= 0:
			continue
		var crop: Image = clean.get_region(rect)
		crop.resize(rect.size.x * 8, rect.size.y * 8, Image.INTERPOLATE_NEAREST)
		crop.save_png(OUT_DIR + "/crop_%s.png" % spec[2])

	# --- the normal spread: four props 4 m apart -----------------------------------------
	var spread_plates: Array[Rect2] = []
	var spread_props: Array[Rect2] = []
	pm.call("_process", 0.0)
	for prop in props:
		prop.call("_track_nameplate")
	for prop in props:
		spread_plates.append(_plate_rect(cam, prop, canvas_scale))
		spread_props.append(_prop_rect(cam, prop, canvas_scale))
	var spread_bad: String = ""
	for i in range(spread_plates.size()):
		for j in range(spread_plates.size()):
			if i == j:
				continue
			if spread_plates[i].intersects(spread_plates[j]):
				spread_bad += "plate%d-plate%d " % [i, j]
			if spread_plates[i].intersects(spread_props[j]):
				spread_bad += "plate%d-prop%d " % [i, j]
	_ok(spread_bad.is_empty(), "spread-out plates keep clear", spread_bad)

	# --- clustered plates ---------------------------------------------------------------
	# Bring the pair 2 m apart: with ~110 px-wide plates that is the case that used to put
	# one name on top of the other. 4 m apart they happen not to overlap, which would pass
	# the assertion without proving anything.
	props[0].position.x = -1.0
	props[1].position.x = 1.0
	for prop in props:
		prop.call("_track_nameplate")
	pm.call("_process", 0.0)
	for prop in props:
		prop.call("_track_nameplate")
	for f in range(3):
		await process_frame
	var cluster: Image = root.get_viewport().get_texture().get_image()
	cluster.save_png(OUT_DIR + "/props_cluster.png")

	var plate_rects: Array[Rect2] = []
	for i in [0, 1]:
		var prop: FloatingProp = props[i]
		var spec: Array = specs[i]
		var text: String = prop.nameplate_label.text
		_ok(text.find("\n") == -1, spec[1] + " plate is one line", "'" + text + "'")

		var plate: Vector2 = prop.nameplate_size_world()
		var anchor: Vector3 = prop.nameplate_label.position
		var centre: Vector2 = cam.unproject_position(anchor) * canvas_scale
		var half_right: Vector3 = cam.global_transform.basis.x * plate.x * 0.5
		var w_px: float = (cam.unproject_position(anchor - half_right) * canvas_scale).distance_to(
			cam.unproject_position(anchor + half_right) * canvas_scale)
		var line_m: float = float(prop.nameplate_label.font_size) * prop.nameplate_label.pixel_size
		var h_px: float = (cam.unproject_position(anchor + Vector3(0, line_m, 0)) * canvas_scale).distance_to(centre)
		plate_rects.append(Rect2(centre - Vector2(w_px, h_px) * 0.5, Vector2(w_px, h_px)))
		print("%-14s plate %3.0f x %2.0f px at (%.0f,%.0f), lift %.2f m, world %.2f x %.2f m" %
			[spec[1], w_px, h_px, centre.x, centre.y, prop.nameplate_lift, plate.x, plate.y])

		var rect: Rect2i = Rect2i(int(centre.x - w_px * 0.5) - 6, int(centre.y - h_px * 0.5) - 6,
			int(w_px) + 12, int(h_px) + 12)
		rect = rect.intersection(Rect2i(Vector2i(4, 4), VIEW - Vector2i(8, 8)))
		if rect.size.x > 0 and rect.size.y > 0:
			var crop: Image = cluster.get_region(rect)
			crop.resize(rect.size.x * 6, rect.size.y * 6, Image.INTERPOLATE_NEAREST)
			crop.save_png(OUT_DIR + "/plate_%s.png" % spec[2])

	_ok(plate_rects[0].intersects(plate_rects[1]) == false, "clustered plates do not overlap",
		"duck lift %.2f m, crate lift %.2f m" % [props[0].nameplate_lift, props[1].nameplate_lift])
	var duck_box: Rect2 = _prop_rect(cam, props[0], canvas_scale)
	var crate_box: Rect2 = _prop_rect(cam, props[1], canvas_scale)
	var ov1: Rect2 = plate_rects[0].intersection(crate_box)
	var ov2: Rect2 = plate_rects[1].intersection(duck_box)
	_ok(plate_rects[0].intersects(crate_box) == false, "duck plate stays off the crate",
		"%.0f x %.0f px overlap" % [ov1.size.x, ov1.size.y])
	_ok(plate_rects[1].intersects(duck_box) == false, "crate plate stays off the duck",
		"%.0f x %.0f px overlap, crate scale %.2f lift %.2f" %
		[ov2.size.x, ov2.size.y, props[1].nameplate_scale, props[1].nameplate_lift])
	_ok(props[0].nameplate_label.modulate != props[2].nameplate_label.modulate,
		"tier colour distinguishes plates",
		"rose %s vs lion %s" % [props[0].nameplate_label.modulate.to_html(false),
			props[2].nameplate_label.modulate.to_html(false)])

	# --- four props in one huddle -------------------------------------------------------
	# This is where a fixed stack limit lets the fourth plate overlap silently.
	var huddle: Array = [Vector3(-0.8, 0.0, -1.6), Vector3(0.8, 0.0, -1.6),
		Vector3(-0.8, 0.0, -0.6), Vector3(0.8, 0.0, -0.6)]
	for i in range(props.size()):
		props[i].position = Vector3(huddle[i].x, props[i].position.y, huddle[i].z)
		props[i].call("_track_nameplate")
	pm.call("_process", 0.0)
	for prop in props:
		prop.call("_track_nameplate")
	for f in range(3):
		await process_frame
	root.get_viewport().get_texture().get_image().save_png(OUT_DIR + "/props_huddle.png")

	var plate_boxes: Array[Rect2] = []
	var prop_boxes: Array[Rect2] = []
	for prop in props:
		plate_boxes.append(_plate_rect(cam, prop, canvas_scale))
		prop_boxes.append(_prop_rect(cam, prop, canvas_scale))

	var collisions: String = ""
	for i in range(plate_boxes.size()):
		for j in range(plate_boxes.size()):
			if i == j:
				continue
			if plate_boxes[i].intersects(plate_boxes[j]):
				collisions += "plate%d-plate%d " % [i, j]
			if plate_boxes[i].intersects(prop_boxes[j]):
				collisions += "plate%d-prop%d " % [i, j]
	_ok(collisions.is_empty(), "huddled plates clear of each other and the props", collisions)

	var smallest: float = 1.0
	for prop in props:
		smallest = minf(smallest, prop.nameplate_scale)
	_ok(smallest >= 0.6, "huddled plates stay legible", "smallest scale %.2f" % smallest)

	# --- six props: the density where lifting alone runs out ------------------------------
	# Gift spam is the case this exists for; if the layout cannot place six plates without
	# shrinking, the shrink step is dead code.
	for pos in [Vector3(-1.9, 0.0, -1.0), Vector3(1.9, 0.0, -1.0)]:
		var spam: FloatingProp = pm.spawn_prop(FloatingProp.PropClass.GIFT_CRATE, "spam_fan",
			"Rose", 10, Vector3(pos.x, props[0].position.y, pos.z))
		spam.set_process(false)
		props.append(spam)
	for prop in props:
		prop.call("_track_nameplate")
	pm.call("_process", 0.0)
	for prop in props:
		prop.call("_track_nameplate")
	for f in range(3):
		await process_frame
	root.get_viewport().get_texture().get_image().save_png(OUT_DIR + "/props_spam.png")

	var spam_plates: Array[Rect2] = []
	var spam_props: Array[Rect2] = []
	for prop in props:
		spam_plates.append(_plate_rect(cam, prop, canvas_scale))
		spam_props.append(_prop_rect(cam, prop, canvas_scale))
	# Text-on-text is the unreadable case, so that is the hard assertion here. Plate-on-prop
	# is a preference the layout gives up in a pile this dense; it is reported, not failed.
	var spam_collisions: String = ""
	var over_props: int = 0
	for i in range(spam_plates.size()):
		for j in range(spam_plates.size()):
			if i == j:
				continue
			if spam_plates[i].intersects(spam_plates[j]):
				spam_collisions += "plate%d-plate%d " % [i, j]
			if spam_plates[i].intersects(spam_props[j]):
				over_props += 1
	_ok(spam_collisions.is_empty(), "six plates stay clear of each other", spam_collisions)
	print("note: %d plate-over-prop overlaps in the six-prop pile" % (over_props / 2))
	var spam_min: float = 1.0
	for prop in props:
		spam_min = minf(spam_min, prop.nameplate_scale)
	_ok(spam_min < 1.0, "dense clusters shrink rather than climb", "smallest scale %.2f" % spam_min)
	_ok(spam_min >= 0.6, "shrunk plates stay legible", "smallest scale %.2f" % spam_min)

	if update_baseline:
		_write_baseline(measured, measured_line_px)
	else:
		_compare_line_height(measured_line_px, baseline, strict)

	var file: FileAccess = FileAccess.open(OUT_PATH, FileAccess.WRITE)
	file.store_string("\n".join(lines) + "\n")
	file.close()

	if softs > 0:
		print("--- %d soft comparisons, none counted as failures (renderer environment differs from the baseline) ---" % softs)
	print("--- %d checks, %d failures ---" % [checks, failures])
	quit(1 if failures > 0 else 0)
