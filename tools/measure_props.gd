extends SceneTree

## Windowed 720p silhouette check for the props and their nameplates, compared against the
## tracked baseline in tools/prop_silhouette_720p.json. "The duck did not move" is then a
## number in the repo rather than a claim in a chat log:
##
##   "$GODOT" --path . --script res://tools/measure_props.gd
##   "$GODOT" --path . --script res://tools/measure_props.gd -- --update-baseline
##
## Deliberately not part of tools/check.sh: it needs a real framebuffer and a window, and
## headless CI has neither. Props sit fully inside the frame and the sim is stepped a fixed
## number of times, so two runs are comparable. PNGs land in .verify/ (gitignored).

const VIEW: Vector2i = Vector2i(1280, 720)
const KEY: Color = Color(1.0, 0.0, 1.0)
const SETTLE_TICKS: int = 120
const DT: float = 1.0 / 30.0
const OUT_PATH: String = "user://prop_measure.txt"
const OUT_DIR: String = "res://.verify"
const BASELINE_PATH: String = "res://tools/prop_silhouette_720p.json"
## Measured edges move by about a pixel between runs (antialiasing), so the baseline is a
## band rather than an exact value.
const SIZE_TOLERANCE_PX: int = 2
const AREA_TOLERANCE_PCT: float = 8.0

var checks: int = 0
var failures: int = 0

func _initialize() -> void:
	_run()

func _ok(condition: bool, label: String, detail: String = "") -> void:
	checks += 1
	if not condition:
		failures += 1
	print(("PASS " if condition else "FAIL ") + label + ("" if detail.is_empty() else "  " + detail))

## The baseline is about geometry, and plates are wider than the props they label. The
## keyed test would also pick up a warm-coloured plate (Rose ffb 1.0/0.4/0.6 passes it), so
## every plate is hidden while a silhouette is captured.
func _set_plates_visible(props: Array, state: bool) -> void:
	for prop in props:
		if is_instance_valid(prop) and prop.nameplate_label:
			prop.nameplate_label.visible = state

func _meshes(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child is MeshInstance3D and child.mesh:
			out.append(child)
		_meshes(child, out)

func _key_area(img: Image) -> Dictionary:
	var mask: PackedByteArray = PackedByteArray()
	mask.resize(VIEW.x * VIEW.y)
	for y in range(VIEW.y):
		for x in range(VIEW.x):
			var c: Color = img.get_pixel(x, y)
			mask[y * VIEW.x + x] = 1 if (c.r > 0.30 and c.b > 0.30 and c.g < 0.45 * c.r and c.g < 0.45 * c.b) else 0

	var min_x: int = VIEW.x
	var min_y: int = VIEW.y
	var max_x: int = -1
	var max_y: int = -1
	var area: int = 0
	for y in range(1, VIEW.y - 1):
		for x in range(1, VIEW.x - 1):
			if mask[y * VIEW.x + x] == 0:
				continue
			if mask[(y - 1) * VIEW.x + x] == 0 or mask[(y + 1) * VIEW.x + x] == 0:
				continue
			if mask[y * VIEW.x + (x - 1)] == 0 or mask[y * VIEW.x + (x + 1)] == 0:
				continue
			area += 1
			min_x = mini(min_x, x)
			max_x = maxi(max_x, x)
			min_y = mini(min_y, y)
			max_y = maxi(max_y, y)

	if area == 0:
		return {"area": 0, "w": 0, "h": 0}
	return {"area": area, "w": max_x - min_x + 1, "h": max_y - min_y + 1}

func _load_baseline() -> Dictionary:
	if not FileAccess.file_exists(BASELINE_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(BASELINE_PATH))
	return parsed if parsed is Dictionary else {}

func _compare_silhouette(label: String, sil: Dictionary, baseline: Dictionary) -> void:
	var recorded: Dictionary = baseline.get("props", {})
	var entry: Dictionary = recorded.get(label, {})
	if entry.is_empty():
		_ok(false, label + " has a baseline entry", "run once with -- --update-baseline")
		return
	var base_w: int = int(entry.get("w", 0))
	var base_h: int = int(entry.get("h", 0))
	_ok(absi(int(sil["w"]) - base_w) <= SIZE_TOLERANCE_PX
			and absi(int(sil["h"]) - base_h) <= SIZE_TOLERANCE_PX,
		label + " size matches the baseline",
		"%dx%d vs baseline %dx%d" % [sil["w"], sil["h"], base_w, base_h])
	var base_area: float = maxf(float(entry.get("area", 1)), 1.0)
	var delta_pct: float = absf(float(sil["area"]) - base_area) / base_area * 100.0
	_ok(delta_pct <= AREA_TOLERANCE_PCT, label + " silhouette area",
		"%d px2 vs baseline %d (%.1f%%)" % [sil["area"], int(base_area), delta_pct])

func _compare_line_height(line_px: int, baseline: Dictionary) -> void:
	var base_line: int = int(baseline.get("nameplate_line_px", 0))
	if base_line <= 0:
		_ok(false, "baseline has a nameplate line height", "run once with -- --update-baseline")
		return
	_ok(absi(line_px - base_line) <= SIZE_TOLERANCE_PX,
		"nameplate line height matches the baseline", "%d px vs baseline %d" % [line_px, base_line])

func _write_baseline(measured: Dictionary, line_px: int) -> void:
	var doc: Dictionary = {
		"view": "1280x720, default camera, 16:9",
		"tolerance": {"size_px": SIZE_TOLERANCE_PX, "area_percent": AREA_TOLERANCE_PCT},
		"nameplate_line_px": line_px,
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

	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.set_process(false) # the harness owns the clock

	var cam: Camera3D = main.get_node("CameraPivot/Camera3D")
	var pm: PropManager = main.get_node("Arena/PropManager")
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
	print("--- silhouette at %dx%d, %d settle ticks ---" % [VIEW.x, VIEW.y, SETTLE_TICKS])
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
		for f in range(3):
			await process_frame
		var frame: Image = root.get_viewport().get_texture().get_image()
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
			_compare_silhouette(spec[1], sil, baseline)

		var line_m: float = float(prop.nameplate_label.font_size) * prop.nameplate_label.pixel_size
		var a: Vector2 = cam.unproject_position(prop.nameplate_label.position)
		var b: Vector2 = cam.unproject_position(prop.nameplate_label.position + Vector3(0, line_m, 0))
		measured_line_px = int(round((b - a).length()))
		_ok(measured_line_px >= 11, spec[1] + " plate legible", "%d px line" % measured_line_px)

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
	_ok(props[0].nameplate_lift > 0.0 or props[1].nameplate_lift > 0.0,
		"a colliding plate was lifted", "duck %.2f m, crate %.2f m" %
		[props[0].nameplate_lift, props[1].nameplate_lift])
	# One plate box of clearance is a clean stagger; three would leave the label floating far
	# from the prop it belongs to.
	_ok(props[0].nameplate_label.modulate != props[2].nameplate_label.modulate,
		"tier colour distinguishes plates",
		"rose %s vs lion %s" % [props[0].nameplate_label.modulate.to_html(false),
			props[2].nameplate_label.modulate.to_html(false)])
	var box_h: float = props[0].nameplate_size_world().y
	var lift: float = maxf(props[0].nameplate_lift, props[1].nameplate_lift)
	_ok(lift <= box_h * 1.5, "the lift stays near one plate height",
		"%.2f m lift vs %.2f m box" % [lift, box_h])

	if update_baseline:
		_write_baseline(measured, measured_line_px)
	else:
		_compare_line_height(measured_line_px, baseline)

	var file: FileAccess = FileAccess.open(OUT_PATH, FileAccess.WRITE)
	file.store_string("\n".join(lines) + "\n")
	file.close()

	print("--- %d checks, %d failures ---" % [checks, failures])
	quit(1 if failures > 0 else 0)
