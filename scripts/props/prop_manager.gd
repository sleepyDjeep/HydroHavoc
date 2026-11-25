class_name PropManager
extends Node3D

## Spawns, manages, and cleans up floating props (ducks, crates, anchors, mascots)
## connecting stream donations directly to 3D physical entities in the water.

signal prop_vaporized_in_steam(prop_name: String, donor: String, bonus_pts: int)
signal prop_plunged(prop_name: String, donor: String)
## Emitted instead of spawning when the live-prop budget is already spent.
signal prop_spawn_blocked(prop_name: String, used: float)

## A sixteen-character plate is roughly 120 px wide at 720p while the prop it labels is
## about 60 px, so props that drift close put their text on top of each other and over the
## neighbour's geometry. This pass lays the plates out in screen space, where the
## collisions actually happen: it prefers a smaller plate over a higher one, so names stay
## near the prop they belong to, and it remembers last frame's choice so a plate does not
## hop rows as two props drift past each other.
const PLATE_STACK_LIMIT: int = 6
const PLATE_GAP_PX: float = 10.0
## Shrink steps, largest first. The smallest keeps the line at ~16 px at 720p, above the
## 11 px the legibility check asserts and above the old 0.12 m text that read badly.
const PLATE_SCALES: Array[float] = [1.0, 0.85, 0.72, 0.6]

## Live-prop budget, in mascot-equivalents, because a mascot is by far the most expensive
## thing a donor can drop: the 2026 gameplay benchmark (fixed 60 fps, this machine) measured
## 32 mascots at 10.96 ms median / 13.27 ms p95 against a 6.14 ms empty frame, and 32 crates
## at 8.81 ms. Nothing else brakes gift spam - props leave only by boiling or plunging - so
## this is a hard ceiling: past it spawn_prop() refuses the prop and the game says so.
## 36 units is the top of the safe band (~36 mascots, or a mixed pile of about 64), not the
## point where frames start missing.
const PROP_BUDGET: float = 36.0
## Cost of each class in those units, scaled from the measured per-prop frame cost.
const PROP_WEIGHTS: Dictionary = {
	FloatingProp.PropClass.STREAMER_MASCOT: 1.0,
	FloatingProp.PropClass.HEAVY_ANCHOR: 0.6,
	FloatingProp.PropClass.GIFT_CRATE: 0.5,
	FloatingProp.PropClass.RUBBER_DUCK: 0.4,
}

var fluid_sim: FluidSim
var active_props: Array[FloatingProp] = []

func _ready() -> void:
	pass

func setup(p_sim: FluidSim) -> void:
	fluid_sim = p_sim

func _process(_delta: float) -> void:
	_stagger_nameplates()

func _plate_rect(centre: Vector2, full: Vector2, scale: float, lift_px: float) -> Rect2:
	var size: Vector2 = full * scale
	return Rect2(centre - size * 0.5 - Vector2(0.0, lift_px), size)

## Screen bounds of a world-space box, from its eight projected corners.
func _screen_rect(cam: Camera3D, box: AABB) -> Rect2:
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
	return Rect2(lo, hi - lo)

## Plate-on-plate is the unreadable case and is never allowed while a slot exists.
## Plate-on-prop only costs some contrast (the text is bright with a heavy outline), so it
## is a preference: in a genuinely dense pile the layout drops it rather than stacking a
## name a metre and a half above the prop it belongs to.
func _fits(rect: Rect2, prop: FloatingProp, placed: Array, prop_rects: Dictionary,
		avoid_props: bool) -> bool:
	for taken in placed:
		if rect.intersects(taken):
			return false
	if not avoid_props:
		return true
	for other in prop_rects:
		if other == prop:
			continue # the plate sits above its own prop by design
		if rect.intersects(prop_rects[other]):
			return false
	return true

func _stagger_nameplates() -> void:
	if active_props.is_empty():
		return

	var previous: Dictionary = {}
	for prop in active_props:
		if not is_instance_valid(prop):
			continue
		previous[prop] = [prop.nameplate_scale, prop.nameplate_lift]
		prop.nameplate_lift = 0.0
		prop.nameplate_scale = 1.0
	if active_props.size() < 2:
		return

	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		return

	var prop_rects: Dictionary = {}
	var items: Array = []
	for prop in active_props:
		if not is_instance_valid(prop) or prop.has_plunged or not prop.nameplate_label:
			continue
		prop_rects[prop] = _screen_rect(cam, prop.visual_box_world())
		var anchor: Vector3 = prop.nameplate_anchor_world()
		var plate: Vector2 = prop.nameplate_size_world()
		var centre: Vector2 = cam.unproject_position(anchor)
		# Two different scales, because the camera looks down at the arena. A billboarded
		# plate is measured against the camera plane, but the lift moves it along world up,
		# which projects shorter by the cosine of the camera pitch (about 30% here). Using
		# one scale for both made plates look narrower than they draw and lifted them less
		# than intended, which is how two plates fitted the same slot.
		var half_right: Vector3 = cam.global_transform.basis.x * maxf(plate.x, 0.1) * 0.5
		var width_px: float = cam.unproject_position(anchor - half_right).distance_to(
			cam.unproject_position(anchor + half_right))
		var px_per_plate_m: float = maxf(centre.distance_to(
			cam.unproject_position(anchor + cam.global_transform.basis.y)), 0.001)
		var px_per_world_m: float = maxf(centre.distance_to(
			cam.unproject_position(anchor + Vector3.UP)), 0.001)
		items.append({
			"prop": prop,
			"centre": centre,
			"size": Vector2(width_px, maxf(plate.y, 0.1) * px_per_plate_m),
			"px_per_m": px_per_world_m,
		})
	items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["centre"].x < b["centre"].x)

	var placed: Array[Rect2] = []
	for item in items:
		var prop: FloatingProp = item["prop"]
		var centre: Vector2 = item["centre"]
		var full: Vector2 = item["size"]
		var px_per_m: float = item["px_per_m"]

		# Last frame's placement is tried first, so a settled cluster stays settled.
		var prev: Array = previous.get(prop, [1.0, 0.0])
		var choices: Array = [[float(prev[0]), float(prev[1])]]
		for level in range(PLATE_STACK_LIMIT + 1):
			for scale in PLATE_SCALES:
				choices.append([scale, level * (full.y * scale + PLATE_GAP_PX)])

		var last_scale: float = PLATE_SCALES[PLATE_SCALES.size() - 1]
		var chosen: Rect2 = _plate_rect(centre, full, last_scale,
			PLATE_STACK_LIMIT * (full.y * last_scale + PLATE_GAP_PX))
		var chosen_scale: float = last_scale
		var placed_ok: bool = false
		for avoid_props in [true, false]:
			for choice in choices:
				var rect: Rect2 = _plate_rect(centre, full, choice[0], choice[1])
				if _fits(rect, prop, placed, prop_rects, avoid_props):
					chosen = rect
					chosen_scale = choice[0]
					placed_ok = true
					break
			if placed_ok:
				break
		placed.append(chosen)
		prop.nameplate_scale = chosen_scale
		# Convert the chosen lift back to world units for the 3D label.
		prop.nameplate_lift = maxf(0.0, (centre.y - full.y * chosen_scale * 0.5) - chosen.position.y) / px_per_m

func prop_weight(prop_class: FloatingProp.PropClass) -> float:
	return float(PROP_WEIGHTS.get(prop_class, 1.0))

## Weight of the props still in play. Plunged props are already falling out of the arena and
## stop rendering, so they stop counting here too: the cap follows what is drawn.
func used_budget() -> float:
	var total: float = 0.0
	for prop in active_props:
		if is_instance_valid(prop) and not prop.has_plunged:
			total += prop_weight(prop.prop_class)
	return total

func spawn_prop(prop_class: FloatingProp.PropClass, donor: String, tier: String, val: int, spawn_pos: Vector3) -> FloatingProp:
	# Before anything is built, so a refused spawn leaves no splash, no vfx and no tracking.
	var weight: float = prop_weight(prop_class)
	var used: float = used_budget()
	if used + weight > PROP_BUDGET + 0.0001:
		emit_signal("prop_spawn_blocked", _get_prop_display_name(prop_class), used)
		return null

	var prop: FloatingProp = FloatingProp.new()
	prop.position = spawn_pos
	# Configure before the node enters the tree: _ready() builds the visuals, so the
	# class has to be assigned first or every prop renders as the RUBBER_DUCK default.
	prop.setup(fluid_sim, prop_class, donor, tier, val)
	add_child(prop)

	prop.plunged_over_waterfall.connect(_on_prop_plunged)
	prop.boiled_in_steam.connect(_on_prop_boiled)

	active_props.append(prop)

	# Trigger initial entry splash wave in the water grid
	if fluid_sim:
		var wave_power: float = 0.5
		if prop_class == FloatingProp.PropClass.HEAVY_ANCHOR:
			wave_power = 1.6
		fluid_sim.inject_splash_wave(spawn_pos.x, spawn_pos.z, wave_power)

	_spawn_splash_vfx(spawn_pos)
	return prop

func check_evaporate_props_in_radius(center_x: int, center_y: int, radius: int) -> int:
	var half: float = float(FluidSim.GRID_SIZE) * 0.5
	var center_world: Vector2 = Vector2(float(center_x) - half + 0.5, float(center_y) - half + 0.5)
	var r2: float = float(radius * radius)
	var total_bonus: int = 0

	for i in range(active_props.size() - 1, -1, -1):
		var p: FloatingProp = active_props[i]
		if not is_instance_valid(p) or p.has_plunged:
			continue

		var p_pos2: Vector2 = Vector2(p.position.x, p.position.z)
		if center_world.distance_squared_to(p_pos2) <= r2:
			var pts: int = p.gift_value * 25
			total_bonus += pts
			emit_signal("prop_vaporized_in_steam", _get_prop_display_name(p.prop_class), p.donor_name, pts)
			_spawn_steam_confetti_vfx(p.position)
			active_props.remove_at(i)
			p.trigger_steam_boil()

	return total_bonus

func _on_prop_plunged(prop: FloatingProp) -> void:
	emit_signal("prop_plunged", _get_prop_display_name(prop.prop_class), prop.donor_name)
	active_props.erase(prop)

func _on_prop_boiled(prop: FloatingProp) -> void:
	active_props.erase(prop)

func _get_prop_display_name(p_class: FloatingProp.PropClass) -> String:
	match p_class:
		FloatingProp.PropClass.RUBBER_DUCK:
			return "Rubber Duck"
		FloatingProp.PropClass.GIFT_CRATE:
			return "Gift Crate"
		FloatingProp.PropClass.HEAVY_ANCHOR:
			return "Heavy Anchor"
		FloatingProp.PropClass.STREAMER_MASCOT:
			return "Streamer Mascot"
		_:
			return "Prop"

func _spawn_splash_vfx(pos: Vector3) -> void:
	# Clean procedural expanding splash ring
	var ring: MeshInstance3D = MeshInstance3D.new()
	var torus: TorusMesh = TorusMesh.new()
	torus.inner_radius = 0.2
	torus.outer_radius = 0.35
	ring.mesh = torus
	ring.position = Vector3(pos.x, pos.y + 0.1, pos.z)

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.7, 0.95, 1.0, 0.8)
	ring.material_override = mat
	add_child(ring)

	var tw: Tween = create_tween().set_parallel(true)
	tw.tween_property(ring, "scale", Vector3(3.0, 0.3, 3.0), 0.45).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.45)
	tw.chain().tween_callback(ring.queue_free)

func _spawn_steam_confetti_vfx(pos: Vector3) -> void:
	# Steam expansion sphere
	var steam: MeshInstance3D = MeshInstance3D.new()
	var sm: SphereMesh = SphereMesh.new()
	sm.radius = 0.5
	sm.height = 1.0
	steam.mesh = sm
	steam.position = pos

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.95, 0.8, 0.9)
	steam.material_override = mat
	add_child(steam)

	var tw: Tween = create_tween().set_parallel(true)
	tw.tween_property(steam, "scale", Vector3(2.5, 3.5, 2.5), 0.5).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(steam, "position:y", pos.y + 2.0, 0.5)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.5)
	tw.chain().tween_callback(steam.queue_free)
