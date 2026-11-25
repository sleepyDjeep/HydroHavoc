extends SceneTree

## Float-height regression test that runs headless, so the gate catches a prop that starts
## sitting too high or too deep instead of waiting for someone to notice on screen.
##
## The silhouette harness hides the water to get reproducible pixels, which left float height
## unmeasured: nothing else in the gate knows where a prop sits in the water. The authored
## rule (floating_prop.gd) is
##     draft = SUBMERGE_FRACTION * TARGET_VISUAL_HEIGHT - _get_prop_y_offset()
## i.e. the node origin is placed _get_prop_y_offset() above the surface and the geometry is
## seated SUBMERGE_FRACTION of its height below that origin, so the bottom of the prop ends up
## `draft` metres under the waterline.
##
## Two halves:
##  1. the authored tables: submerge fraction, offset, the resulting draft, and that the
##     measured seating agrees with the fraction (the seat and the fraction are tuned together).
##  2. the behaviour: each class is settled into a real 2 m basin of a real FluidSim by calling
##     the prop's own _process, and the settled geometry has to land where the tables say. That
##     is what catches a change to the runtime path rather than to a constant.
##
## The heavy anchor is the exception the tables cannot describe: in water deeper than the prop
## is tall it sinks to the bed and rests 0.25 m above it (_process), so its surface-relative
## draft only applies on shallow ground. The test pins that bed clearance separately.

const BASELINE_PATH: String = "res://tests/float_height_baseline.json"
## The authored values are exact constants with no measurement in them.
const TOL_M: float = 0.005
## The settled half runs the real _process, so it also carries the bob and the lerp.
const TOL_SETTLED: float = 0.02
const BASIN_DEPTH: float = 2.0
const BASIN_RADIUS: int = 4
const SETTLE_TICKS: int = 240
## The position lerps towards the surface at delta * 12, so skip the approach.
const WARMUP_TICKS: int = 60
const DT: float = 1.0 / 30.0

var checks: int = 0
var failures: int = 0

func _initialize() -> void:
	_run()

func _ok(condition: bool, label: String, detail: String = "") -> void:
	checks += 1
	if not condition:
		failures += 1
	print(("PASS " if condition else "FAIL ") + label + ("" if detail.is_empty() else "  " + detail))

func _load_baseline() -> Dictionary:
	if not FileAccess.file_exists(BASELINE_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(BASELINE_PATH))
	return parsed if parsed is Dictionary else {}

func _spawn(parent: Node, sim: FluidSim, cls: int) -> FloatingProp:
	var prop: FloatingProp = FloatingProp.new()
	# setup() before add_child: the class has to be set before _ready() builds the visuals.
	prop.setup(sim, cls, "float_check", "Rose", 10)
	parent.add_child(prop)
	prop.set_process(false)
	return prop

## A flat basin of BASIN_DEPTH around cell (16,16), which is the cell world position (0,0)
## lands in. The water is placed directly rather than stepped, so the surface stays put while
## the prop is driven and every number below is surface-relative.
func _basin() -> FluidSim:
	var sim: FluidSim = FluidSim.new()
	var centre: int = int(FluidSim.GRID_SIZE * 0.5)
	for dz in range(-BASIN_RADIUS, BASIN_RADIUS + 1):
		for dx in range(-BASIN_RADIUS, BASIN_RADIUS + 1):
			sim.add_water(centre + dx, centre + dz, BASIN_DEPTH)
	return sim

## Drop a prop into the basin and let its own _process settle it, then describe where the
## geometry ended up relative to the water surface.
func _settle(main: Node, cls: int) -> Dictionary:
	var sim: FluidSim = _basin()
	var surface: float = sim.get_water_height_at_world_pos(0.0, 0.0)
	var depth: float = sim.get_water_depth_at_world_pos(0.0, 0.0)
	var prop: FloatingProp = _spawn(main, sim, cls)
	prop.position = Vector3(0.0, surface, 0.0)
	# Already floating: the entry splash would inject water into the basin and move the surface
	# out from under the prop while it is being measured.
	prop.is_in_water = true

	var sum_y: float = 0.0
	var samples: int = 0
	for i in range(SETTLE_TICKS):
		prop._process(DT)
		if i >= WARMUP_TICKS:
			sum_y += prop.position.y
			samples += 1
	var mean_y: float = sum_y / float(samples)

	# Measure the footprint at the settled height rather than at wherever the bob left it.
	prop.position.y = mean_y
	var box: AABB = prop.visual_box_world()
	var settled: Dictionary = {
		"surface": surface,
		"depth": depth,
		"origin_dy": mean_y - surface,
		"bottom_dy": box.position.y - surface,
		"top_dy": box.position.y + box.size.y - surface,
	}
	prop.free()
	return settled

func _run() -> void:
	# Suspend once: quit() from _initialize() without an await hangs instead of exiting.
	await process_frame
	# rocking_seed is drawn from the global RNG per prop, so the bob phase (and with it the
	# settled mean) would move by a few millimetres between runs.
	seed(0)

	var update: bool = OS.get_cmdline_user_args().has("--update-baseline")
	var baseline: Dictionary = _load_baseline()

	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.set_process(false)

	# The behaviour half assumes the depth it thinks it has: the anchor's rule is bed-relative.
	var probe: Dictionary = _settle(main, FloatingProp.PropClass.RUBBER_DUCK)
	_ok(absf(float(probe["surface"]) - BASIN_DEPTH) <= TOL_M
			and absf(float(probe["depth"]) - BASIN_DEPTH) <= TOL_M,
		"basin holds %.1f m of water" % BASIN_DEPTH,
		"surface %.2f m, depth %.2f m" % [probe["surface"], probe["depth"]])

	var specs: Array = [
		[FloatingProp.PropClass.RUBBER_DUCK, "Rubber Duck"],
		[FloatingProp.PropClass.GIFT_CRATE, "Gift Crate"],
		[FloatingProp.PropClass.HEAVY_ANCHOR, "Heavy Anchor"],
		[FloatingProp.PropClass.STREAMER_MASCOT, "Streamer Mascot"],
	]

	var measured: Dictionary = {}
	for spec in specs:
		var cls: int = spec[0]
		var label: String = spec[1]
		var is_anchor: bool = cls == FloatingProp.PropClass.HEAVY_ANCHOR

		var prop: FloatingProp = _spawn(main, null, cls)
		var submerge: float = FloatingProp.SUBMERGE_FRACTION[cls]
		var target: float = FloatingProp.TARGET_VISUAL_HEIGHT[cls]
		var offset: float = prop._get_prop_y_offset()
		var draft: float = submerge * target - offset
		var seated_top: float = (1.0 - submerge) * target
		var entry: Dictionary = {
			"submerge": snappedf(submerge, 0.0001),
			"offset": snappedf(offset, 0.0001),
			"draft": snappedf(draft, 0.0001),
		}

		# Baseline-free: the seat and the fraction are tuned together, and a prop floating on
		# top of the water is wrong however the tables read.
		_ok(absf(prop.visual_top - seated_top) <= TOL_M,
			label + " seating agrees with the submerge fraction",
			"visual_top %.3f m vs %.3f m" % [prop.visual_top, seated_top])
		_ok(draft > 0.0, label + " sits in the water rather than on top of it",
			"draft %.4f m" % draft)

		var settled: Dictionary = _settle(main, cls)
		if is_anchor:
			# In deep water the bed rule wins, so the authored offset is not what runs. Record
			# what the code actually does and pin that.
			entry["bed_clearance"] = snappedf(float(settled["origin_dy"]) + float(settled["depth"]), 0.0001)
		measured[label] = entry

		if update:
			prop.free()
			continue

		var recorded: Dictionary = baseline.get("props", {}).get(label, {})
		if recorded.is_empty():
			_ok(false, label + " has a baseline entry", "run once with -- --update-baseline")
			prop.free()
			continue

		_ok(absf(submerge - float(recorded.get("submerge", 0.0))) <= TOL_M,
			label + " submerge fraction",
			"%.2f vs baseline %.2f" % [submerge, recorded.get("submerge", 0.0)])
		_ok(absf(offset - float(recorded.get("offset", 0.0))) <= TOL_M,
			label + " y offset",
			"%.2f m vs baseline %.2f m" % [offset, recorded.get("offset", 0.0)])
		_ok(absf(draft - float(recorded.get("draft", 0.0))) <= TOL_M,
			label + " draft below the waterline",
			"%.4f m vs baseline %.4f m" % [draft, recorded.get("draft", 0.0)])

		if is_anchor:
			# The anchor is the one class whose float height is not the surface rule: it stands
			# on the bed, so what matters is that clearance and that it still shows above water.
			var clearance: float = float(recorded.get("bed_clearance", 0.0))
			var expected: float = clearance - float(settled["depth"])
			_ok(absf(float(settled["origin_dy"]) - expected) <= TOL_SETTLED,
				label + " rests on the bed, not on the surface",
				"origin %.2f m vs bed+%.2f m in %.2f m of water"
					% [settled["origin_dy"], clearance, settled["depth"]])
			_ok(float(settled["top_dy"]) > 0.0,
				label + " still clears the surface from the bed",
				"top %+.2f m" % float(settled["top_dy"]))
		else:
			_ok(absf(float(settled["origin_dy"]) - offset) <= TOL_SETTLED,
				label + " settles at its y offset above the surface",
				"origin %+.2f m vs %.2f m" % [settled["origin_dy"], offset])
			_ok(absf(float(settled["bottom_dy"]) + draft) <= TOL_SETTLED,
				label + " draft puts the bottom under the waterline",
				"bottom %+.4f m vs %.4f m" % [settled["bottom_dy"], -draft])
			_ok(absf(float(settled["top_dy"]) - (target - draft)) <= TOL_SETTLED,
				label + " freeboard stands above the waterline",
				"top %+.2f m vs %.3f m" % [settled["top_dy"], target - draft])
		prop.free()

	if update:
		var doc: Dictionary = {
			"note": "surface-relative float height, headless; see tests/float_height.gd",
			"tolerance": {"m": TOL_M, "settled_m": TOL_SETTLED},
			"basin_depth": BASIN_DEPTH,
			"props": measured,
		}
		var file: FileAccess = FileAccess.open(BASELINE_PATH, FileAccess.WRITE)
		file.store_string(JSON.stringify(doc, "\t", true) + "\n")
		file.close()
		print("wrote baseline: " + BASELINE_PATH)

	print("--- %d checks, %d failures ---" % [checks, failures])
	quit(1 if failures > 0 else 0)
