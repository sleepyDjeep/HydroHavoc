class_name PropManager
extends Node3D

## Spawns, manages, and cleans up floating props (ducks, crates, anchors, mascots)
## connecting stream donations directly to 3D physical entities in the water.

signal prop_vaporized_in_steam(prop_name: String, donor: String, bonus_pts: int)
signal prop_plunged(prop_name: String, donor: String)

## A sixteen-character plate is roughly 200 px wide at 720p while the prop it labels is
## about 60 px, so two props that drift close put their text on top of each other. This
## pass stacks a plate a line at a time until it clears the plates already placed this
## frame, left to right.
const PLATE_STACK_LIMIT: int = 3
const PLATE_GAP_PX: float = 4.0

var fluid_sim: FluidSim
var active_props: Array[FloatingProp] = []

func _ready() -> void:
	pass

func _process(_delta: float) -> void:
	_stagger_nameplates()

## Screen-space layout, because whether two plates collide depends on the camera, not on
## the world distance between the props (the view is shallow, so depth compresses).
func _stagger_nameplates() -> void:
	if active_props.is_empty():
		return
	for prop in active_props:
		if is_instance_valid(prop):
			prop.nameplate_lift = 0.0
	if active_props.size() < 2:
		return

	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		return

	var items: Array = []
	for prop in active_props:
		if not is_instance_valid(prop) or prop.has_plunged or not prop.nameplate_label:
			continue
		var anchor: Vector3 = prop.nameplate_anchor_world()
		var plate: Vector2 = prop.nameplate_size_world()
		var centre: Vector2 = cam.unproject_position(anchor)
		var right: Vector3 = cam.global_transform.basis.x * maxf(plate.x, 0.1) * 0.5
		var width_px: float = cam.unproject_position(anchor - right).distance_to(
			cam.unproject_position(anchor + right))
		var px_per_m: float = maxf(centre.distance_to(cam.unproject_position(anchor + Vector3.UP)), 0.001)
		items.append({
			"prop": prop,
			"centre": centre,
			"size": Vector2(width_px, maxf(plate.y, 0.1) * px_per_m),
			"px_per_m": px_per_m,
		})
	items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["centre"].x < b["centre"].x)

	var placed: Array[Rect2] = []
	for item in items:
		var centre: Vector2 = item["centre"]
		var size: Vector2 = item["size"]
		var top_left: Vector2 = centre - size * 0.5
		var candidate: Rect2 = Rect2(top_left, size)
		# Move straight above whichever plate conflicts rather than stepping by a fixed
		# amount: two plates rarely sit at the same height, and a fixed step left a few
		# pixels of overlap that cost another level (and a plate floating off its prop).
		for _pass in range(PLATE_STACK_LIMIT + 1):
			var moved: bool = false
			for taken in placed:
				if candidate.intersects(taken):
					candidate.position.y = taken.position.y - candidate.size.y - PLATE_GAP_PX
					moved = true
			if not moved:
				break
		placed.append(candidate)
		# Convert the chosen lift back to world units for the 3D label.
		item["prop"].nameplate_lift = maxf(0.0, top_left.y - candidate.position.y) / item["px_per_m"]

func setup(p_sim: FluidSim) -> void:
	fluid_sim = p_sim

func spawn_prop(prop_class: FloatingProp.PropClass, donor: String, tier: String, val: int, spawn_pos: Vector3) -> FloatingProp:
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
