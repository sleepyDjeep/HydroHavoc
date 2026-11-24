extends SceneTree

## Prop-size regression test that runs headless, so the gate catches a sizing change
## instead of waiting for someone to notice in a window.
##
## Pixel silhouettes need a framebuffer (tests/measure_props.gd handles those, by hand or
## on a machine with a display). What this checks is everything that *causes* the
## silhouette and can be measured without rendering: the target height the class is
## normalised to, the scale the fit actually chose, where the geometry is seated relative
## to the node origin, and how large that projects at 1280x720 through the game camera.
## Changing TARGET_VISUAL_HEIGHT, SUBMERGE_FRACTION, the fit maths or the mascot multiplier
## fails here.

const VIEW: Vector2i = Vector2i(1280, 720)
const BASELINE_PATH: String = "res://tests/prop_size_baseline.json"
const TOL_PX: float = 1.5
const TOL_SCALE: float = 0.005
const TOL_M: float = 0.005

var checks: int = 0
var failures: int = 0

func _initialize() -> void:
	_run()

func _ok(condition: bool, label: String, detail: String = "") -> void:
	checks += 1
	if not condition:
		failures += 1
	print(("PASS " if condition else "FAIL ") + label + ("" if detail.is_empty() else "  " + detail))

func _screen_size(cam: Camera3D, box: AABB) -> Vector2:
	var lo: Vector2 = Vector2(INF, INF)
	var hi: Vector2 = Vector2(-INF, -INF)
	for i in range(8):
		var corner: Vector3 = box.position + Vector3(
			box.size.x if (i & 1) else 0.0,
			box.size.y if (i & 2) else 0.0,
			box.size.z if (i & 4) else 0.0)
		var p: Vector2 = cam.unproject_position(corner)
		lo = lo.min(p)
		hi = hi.max(p)
	return hi - lo

func _load_baseline() -> Dictionary:
	if not FileAccess.file_exists(BASELINE_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(BASELINE_PATH))
	return parsed if parsed is Dictionary else {}

func _run() -> void:
	# Suspend once: quit() from _initialize() without an await hangs instead of exiting.
	await process_frame

	var update: bool = OS.get_cmdline_user_args().has("--update-baseline")
	var baseline: Dictionary = _load_baseline()

	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.set_process(false)

	var game_cam: Camera3D = main.get_node("CameraPivot/Camera3D")

	# Project through our own 1280x720 viewport: the headless root viewport is square, so
	# unprojecting against it would make the numbers depend on where the test runs.
	var viewport: SubViewport = SubViewport.new()
	viewport.size = VIEW
	root.add_child(viewport)
	var cam: Camera3D = Camera3D.new()
	cam.transform = game_cam.global_transform
	cam.fov = game_cam.fov
	cam.near = game_cam.near
	cam.far = game_cam.far
	viewport.add_child(cam)
	cam.current = true

	var specs: Array = [
		[FloatingProp.PropClass.RUBBER_DUCK, "Rubber Duck", Vector3(-2.0, 2.2, -2.0)],
		[FloatingProp.PropClass.GIFT_CRATE, "Gift Crate", Vector3(2.0, 2.2, -2.0)],
		[FloatingProp.PropClass.HEAVY_ANCHOR, "Heavy Anchor", Vector3(-2.0, 2.2, 1.5)],
		[FloatingProp.PropClass.STREAMER_MASCOT, "Streamer Mascot", Vector3(2.0, 2.2, 1.5)],
	]

	var measured: Dictionary = {}
	for spec in specs:
		var prop: FloatingProp = FloatingProp.new()
		prop.position = spec[2]
		# setup() before add_child: the class has to be set before _ready() builds visuals.
		prop.setup(null, spec[0], "size_check", "Rose", 10)
		main.add_child(prop)

		var px: Vector2 = _screen_size(cam, prop.visual_box_world())
		var entry: Dictionary = {
			"target": FloatingProp.TARGET_VISUAL_HEIGHT[spec[0]],
			"scale": prop.visual_mesh.scale.y,
			"visual_top": prop.visual_top,
			"px_w": snappedf(px.x, 0.1),
			"px_h": snappedf(px.y, 0.1),
		}
		measured[spec[1]] = entry

		if update:
			prop.free()
			continue

		var recorded: Dictionary = baseline.get("props", {}).get(spec[1], {})
		if recorded.is_empty():
			_ok(false, spec[1] + " has a baseline entry", "run once with -- --update-baseline")
			prop.free()
			continue

		_ok(absf(float(entry["target"]) - float(recorded.get("target", 0.0))) <= TOL_M,
			spec[1] + " target height",
			"%.2f m vs baseline %.2f m" % [entry["target"], recorded.get("target", 0.0)])
		_ok(absf(float(entry["scale"]) - float(recorded.get("scale", 0.0))) <= TOL_SCALE,
			spec[1] + " fitted scale",
			"%.2f vs baseline %.2f" % [entry["scale"], recorded.get("scale", 0.0)])
		_ok(absf(float(entry["visual_top"]) - float(recorded.get("visual_top", 0.0))) <= TOL_M,
			spec[1] + " seating",
			"%.2f m vs baseline %.2f m" % [entry["visual_top"], recorded.get("visual_top", 0.0)])
		_ok(absf(float(entry["px_w"]) - float(recorded.get("px_w", 0.0))) <= TOL_PX
				and absf(float(entry["px_h"]) - float(recorded.get("px_h", 0.0))) <= TOL_PX,
			spec[1] + " projected size at 720p",
			"%.0fx%.0f px vs baseline %.0fx%.0f px" % [entry["px_w"], entry["px_h"],
				recorded.get("px_w", 0.0), recorded.get("px_h", 0.0)])
		prop.free()

	if update:
		var doc: Dictionary = {
			"view": "1280x720 projection of the fitted geometry, headless",
			"tolerance": {"px": TOL_PX, "scale": TOL_SCALE},
			"props": measured,
		}
		var file: FileAccess = FileAccess.open(BASELINE_PATH, FileAccess.WRITE)
		file.store_string(JSON.stringify(doc, "\t", true) + "\n")
		file.close()
		print("wrote baseline: " + BASELINE_PATH)

	print("--- %d checks, %d failures ---" % [checks, failures])
	quit(1 if failures > 0 else 0)
