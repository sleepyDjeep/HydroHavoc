class_name FloatingProp
extends Node3D

## Interactive 3D floating object with single-point surface clamping,
## procedural wave rocking, fluid velocity vector advection, and 3D viewer nameplate.

signal plunged_over_waterfall(prop: FloatingProp)
signal boiled_in_steam(prop: FloatingProp)

enum PropClass {
	RUBBER_DUCK,
	GIFT_CRATE,
	HEAVY_ANCHOR,
	STREAMER_MASCOT
}

## Visual-only sizing. Props are read from a camera roughly 20 m out, so a prop needs
## to occupy tens of pixels at 720p to be identifiable at all. Each class is normalised
## to a target height in metres regardless of how big its source mesh happens to be
## (the gift crate GLB is a fraction of the duck). The physics offsets below
## (_get_prop_y_offset, advection, bed clamping) are deliberately not part of this.
const TARGET_VISUAL_HEIGHT: Dictionary = {
	PropClass.RUBBER_DUCK: 1.7,
	PropClass.GIFT_CRATE: 1.35,
	PropClass.HEAVY_ANCHOR: 2.6, # stands on the bed: it has to clear deep water to be seen
	PropClass.STREAMER_MASCOT: 2.2,
}

## The mascot is skinned and its meshes sit under a 0.01-scale node, so its measured
## bounds are ~100x smaller than what the renderer draws (a fitted scale made it metres
## tall). It uses an explicit multiplier instead, and assumes TARGET_VISUAL_HEIGHT when
## seating and placing the nameplate.
const MASCOT_VISUAL_SCALE: float = 1.45 # authored model renders ~1.6 m at scale 1.0

## A fitted scale outside this band almost always means the model's reported bounds do
## not match what renders (the skinned-mascot problem, ~94x). Warn rather than quietly
## ship a prop the size of a building; see MASCOT_VISUAL_SCALE for the known exception.
const MIN_FIT_FACTOR: float = 0.2
const MAX_FIT_FACTOR: float = 10.0

## Share of the visual height that sits below the node origin, so a scaled-up prop still
## looks like it is floating rather than hovering.
##
## This stacks with _get_prop_y_offset(), which lifts the whole node again by 0.1-0.45 m
## per class. The node origin ends up offset twice, and the effective waterline is
##     draft = SUBMERGE_FRACTION * visual height - _get_prop_y_offset()
## so the two tables must be tuned together: moving one alone shifts every prop up or
## down in the water.
const SUBMERGE_FRACTION: Dictionary = {
	PropClass.RUBBER_DUCK: 0.30,
	PropClass.GIFT_CRATE: 0.25,
	PropClass.HEAVY_ANCHOR: 0.12, # physics pins the anchor 0.25 m above the bed
	PropClass.STREAMER_MASCOT: 0.30,
}

@export var prop_class: PropClass = PropClass.RUBBER_DUCK
@export var donor_name: String = "Viewer"
@export var gift_tier: String = "Rose"
@export var gift_value: int = 10

var fluid_sim: FluidSim
var horizontal_vel: Vector2 = Vector2.ZERO
var vertical_vel: float = 0.0
var is_in_water: bool = false
var has_plunged: bool = false
var rocking_seed: float = 0.0
var life_time: float = 0.0

# Visual references
var visual_mesh: Node3D
var nameplate_label: Label3D
var visual_top: float = 0.0 # local height of the fitted geometry, used by the nameplate
## World-space lift applied by PropManager when another plate would overlap this one.
var nameplate_lift: float = 0.0

## Gap between the fitted geometry's top and the plate, in metres.
const PLATE_ABOVE_PROP: float = 0.55

func _ready() -> void:
	rocking_seed = randf() * 100.0
	_build_visuals()
	_build_nameplate()

func setup(p_sim: FluidSim, p_class: PropClass, p_donor: String, p_tier: String, p_val: int) -> void:
	var class_changed: bool = p_class != prop_class
	fluid_sim = p_sim
	prop_class = p_class
	# Stored as the display string, not the raw event payload: this name goes straight
	# onto a nameplate and into the boil/plunge alerts, both of which are on frame.
	donor_name = NamePolicy.display_name(p_donor)
	gift_tier = p_tier
	gift_value = p_val

	if nameplate_label:
		_refresh_nameplate()

	# setup() may arrive after the node is already in the tree, in which case _ready()
	# already built visuals for the default class. Rebuild them for the real one.
	if class_changed and is_inside_tree():
		_rebuild_visuals()

## One line only. The old "[Rose]" second line doubled the plate's height for information
## the colour already carries (a gift's tier is fixed per prop class), and it was the line
## that covered the neighbouring prop when two gifts drifted together.
func _format_nameplate() -> String:
	return "VIP " + donor_name

func _rebuild_visuals() -> void:
	if is_instance_valid(visual_mesh):
		visual_mesh.queue_free()
		visual_mesh = null
	_build_visuals()
	if nameplate_label:
		_refresh_nameplate()

func _process(delta: float) -> void:
	_track_nameplate()

	if not fluid_sim or has_plunged:
		# In freefall down abyss
		vertical_vel -= 18.0 * delta
		position.y += vertical_vel * delta
		rotate_x(delta * 4.0)
		rotate_z(delta * 3.0)
		if position.y < -15.0:
			queue_free()
		return

	life_time += delta
	var half_grid: float = float(FluidSim.GRID_SIZE) * 0.5

	# Check if prop fell off island perimeter into waterfall
	if absf(position.x) >= half_grid or absf(position.z) >= half_grid:
		_trigger_plunge()
		return

	# Query heightfield fluid simulation at prop's world coordinates
	var surface_y: float = fluid_sim.get_water_height_at_world_pos(position.x, position.z)
	var water_depth: float = fluid_sim.get_water_depth_at_world_pos(position.x, position.z)
	var flow_vec: Vector2 = fluid_sim.get_fluid_velocity_at_world_pos(position.x, position.z)

	if water_depth > 0.03:
		# Floating on water!
		if not is_in_water:
			is_in_water = true
			fluid_sim.inject_splash_wave(position.x, position.z, 0.4)

		if prop_class == PropClass.HEAVY_ANCHOR:
			# Heavy anchor sinks to the rocky bed and acts as an obstacle
			var terrain_y: float = surface_y - water_depth
			position.y = lerpf(position.y, terrain_y + 0.25, delta * 8.0)
			# Very low drift
			position.x += flow_vec.x * delta * 0.15
			position.z += flow_vec.y * delta * 0.15
			rotation.y += delta * 0.5
		else:
			# Surface clamping with organic wave bobbing & tilt
			var bob: float = sin(life_time * 4.0 + rocking_seed) * 0.06
			var target_y: float = surface_y + bob + _get_prop_y_offset()
			position.y = lerpf(position.y, target_y, delta * 12.0)

			# Advection along fluid velocity vectors towards drains/outflow
			horizontal_vel = horizontal_vel.lerp(flow_vec * _get_flow_advection_factor(), delta * 4.0)
			position.x += horizontal_vel.x * delta
			position.z += horizontal_vel.y * delta

			# Procedural rocking / roll based on fluid motion
			var rock_x: float = cos(life_time * 3.5 + rocking_seed) * 0.18 + flow_vec.y * 0.1
			var rock_z: float = sin(life_time * 3.5 + rocking_seed) * 0.18 - flow_vec.x * 0.1
			rotation.x = lerp_angle(rotation.x, rock_x, delta * 6.0)
			rotation.z = lerp_angle(rotation.z, rock_z, delta * 6.0)
			rotation.y += horizontal_vel.length() * delta * 2.0
	else:
		# Resting on dry ground or shallow earth
		is_in_water = false
		position.y = lerpf(position.y, surface_y + _get_prop_y_offset(), delta * 10.0)
		rotation.x = lerp_angle(rotation.x, 0.0, delta * 5.0)
		rotation.z = lerp_angle(rotation.z, 0.0, delta * 5.0)

func _get_prop_y_offset() -> float:
	match prop_class:
		PropClass.RUBBER_DUCK:
			return 0.18
		PropClass.GIFT_CRATE:
			return 0.25
		PropClass.HEAVY_ANCHOR:
			return 0.1
		PropClass.STREAMER_MASCOT:
			return 0.45
		_:
			return 0.2

func _get_flow_advection_factor() -> float:
	match prop_class:
		PropClass.RUBBER_DUCK:
			return 1.4 # Floats fast with currents
		PropClass.GIFT_CRATE:
			return 0.9 # Sturdy wooden barge
		PropClass.HEAVY_ANCHOR:
			return 0.08 # Sinks, barely moves
		PropClass.STREAMER_MASCOT:
			return 1.1 # Flailing with water flow
		_:
			return 1.0

func _trigger_plunge() -> void:
	has_plunged = true
	vertical_vel = 2.0
	emit_signal("plunged_over_waterfall", self)

func trigger_steam_boil() -> void:
	emit_signal("boiled_in_steam", self)
	queue_free()

func _build_nameplate() -> void:
	nameplate_label = Label3D.new()
	# Top level so the plate tracks the prop in world space: as a child it inherited the
	# prop's wave rocking, which slid the text sideways off the thing it labels.
	nameplate_label.top_level = true
	nameplate_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	# A 48 px font at this pixel size is ~0.46 m tall in world space: around 23 px at 720p
	# from the default camera, which stays legible where the old 0.12 m text did not.
	# Depth testing is off so the plate reads over its own prop and water.
	nameplate_label.font_size = 48
	nameplate_label.pixel_size = 0.0095
	nameplate_label.outline_size = 12
	nameplate_label.outline_modulate = Color(0.05, 0.05, 0.1, 0.95)
	nameplate_label.no_depth_test = true
	nameplate_label.render_priority = 1
	add_child(nameplate_label)
	_refresh_nameplate()

func _refresh_nameplate() -> void:
	if not nameplate_label:
		return
	nameplate_label.text = _format_nameplate()
	nameplate_label.modulate = _get_tier_color()
	_track_nameplate()

## Called every frame: the plate is a top-level node pinned in world space, so it does not
## inherit the prop's rocking rotation (which used to slide it sideways off the prop).
func _track_nameplate() -> void:
	if nameplate_label and is_inside_tree():
		nameplate_label.position = nameplate_anchor_world() + Vector3(0.0, nameplate_lift, 0.0)

## Where the plate sits above this prop before any stagger is applied, in world space.
func nameplate_anchor_world() -> Vector3:
	return global_position + Vector3(0.0, visual_top + PLATE_ABOVE_PROP, 0.0)

## Footprint of the plate in metres, measured from the font rather than from the node's
## AABB: Label3D reports its box in font pixels, which made the collision test ~7x too big
## and lifted plates the height of the prop. The 1.15 covers line spacing.
func nameplate_size_world() -> Vector2:
	if not nameplate_label:
		return Vector2.ZERO
	var font: Font = nameplate_label.font if nameplate_label.font else ThemeDB.fallback_font
	var px: Vector2 = font.get_string_size(nameplate_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
		nameplate_label.font_size)
	return px * nameplate_label.pixel_size * Vector2(1.0, 1.15)

## The plate colour carries the gift tier now that the "[Rose]" line is gone, using the
## same colours the alert banner uses for that gift.
func _get_tier_color() -> Color:
	match gift_tier.to_lower():
		"rose":
			return Color(1.0, 0.4, 0.6)
		"galaxy":
			return Color(0.6, 0.2, 1.0)
		"lion", "universe":
			return Color(1.0, 0.6, 0.0)
		_:
			return Color(0.85, 0.9, 1.0)

func _build_visuals() -> void:
	match prop_class:
		PropClass.RUBBER_DUCK:
			_create_duck_mesh()
		PropClass.GIFT_CRATE:
			_create_crate_mesh()
		PropClass.HEAVY_ANCHOR:
			_create_anchor_mesh()
		PropClass.STREAMER_MASCOT:
			_create_mascot_mesh()
	_fit_visuals()

## Scales whatever mesh the class built up to its target height and seats it about the
## node origin, leaving the buoyancy/advection offsets untouched.
func _fit_visuals() -> void:
	if not is_instance_valid(visual_mesh):
		return

	# Every class has an entry in both tables, so index rather than default.
	var target: float = TARGET_VISUAL_HEIGHT[prop_class]
	var submerge: float = SUBMERGE_FRACTION[prop_class]

	if prop_class == PropClass.STREAMER_MASCOT:
		visual_mesh.scale = Vector3.ONE * MASCOT_VISUAL_SCALE
		visual_mesh.position.y = -target * submerge
		visual_top = target * (1.0 - submerge)
		return

	var local: AABB = _collect_aabb(visual_mesh, Transform3D.IDENTITY)
	if local.size.y <= 0.0001:
		visual_top = 0.0
		return

	var current: float = local.size.y * visual_mesh.scale.y
	var factor: float = target / maxf(current, 0.0001)
	if factor < MIN_FIT_FACTOR or factor > MAX_FIT_FACTOR:
		# The fit is applied anyway so the prop is still visible, but a wrong-sized prop is
		# now a log line instead of a mystery.
		push_warning("%s: fitted scale %.1fx is outside %.2f-%.1f; check that the model's bounds match what renders"
			% [PropClass.keys()[prop_class], factor, MIN_FIT_FACTOR, MAX_FIT_FACTOR])
	visual_mesh.scale = visual_mesh.scale * factor

	# Seat the geometry so SUBMERGE_FRACTION of its measured height sits below the node
	# origin, which the physics offsets clamp to the water surface.
	var scale_y: float = visual_mesh.scale.y
	visual_mesh.position.y = -(local.position.y + local.size.y * submerge) * scale_y
	visual_top = local.size.y * (1.0 - submerge) * scale_y

## Union of every mesh below `node`, expressed in the given space. Models arrive with
## their own pivots, nested nodes and non-uniform child scales, so the extents have to be
## measured rather than assumed. Returns AABB() (zero size) when there is no geometry;
## the has_box flag exists because merging into a fresh AABB would add the origin.
## Only valid for rigid geometry: see MASCOT_VISUAL_SCALE for the skinned exception.
func _collect_aabb(node: Node3D, xform: Transform3D) -> AABB:
	var box: AABB = AABB()
	var has_box: bool = false

	for child in node.get_children():
		if not child is Node3D:
			continue
		var child_xform: Transform3D = xform * child.transform

		if child is MeshInstance3D and child.mesh:
			var mesh_box: AABB = child_xform * child.mesh.get_aabb()
			box = mesh_box if not has_box else box.merge(mesh_box)
			has_box = true

		var child_box: AABB = _collect_aabb(child, child_xform)
		if child_box.size != Vector3.ZERO:
			box = child_box if not has_box else box.merge(child_box)
			has_box = true

	return box if has_box else AABB()

func _create_duck_mesh() -> void:
	visual_mesh = Node3D.new()
	add_child(visual_mesh)

	# Duck Body (Yellow Sphere/Ellipsoid)
	var body: MeshInstance3D = MeshInstance3D.new()
	var s: SphereMesh = SphereMesh.new()
	s.radius = 0.35
	s.height = 0.6
	body.mesh = s
	body.scale = Vector3(1.0, 0.8, 1.2)
	var mat_yellow: StandardMaterial3D = StandardMaterial3D.new()
	mat_yellow.albedo_color = Color(1.0, 0.82, 0.1)
	mat_yellow.roughness = 0.3
	body.material_override = mat_yellow
	visual_mesh.add_child(body)

	# Duck Head
	var head: MeshInstance3D = MeshInstance3D.new()
	var hs: SphereMesh = SphereMesh.new()
	hs.radius = 0.22
	hs.height = 0.4
	head.mesh = hs
	head.position = Vector3(0, 0.3, 0.22)
	head.material_override = mat_yellow
	visual_mesh.add_child(head)

	# Duck Bill (Orange box/prism)
	var bill: MeshInstance3D = MeshInstance3D.new()
	var b: BoxMesh = BoxMesh.new()
	b.size = Vector3(0.18, 0.08, 0.2)
	bill.mesh = b
	bill.position = Vector3(0, 0.26, 0.42)
	var mat_orange: StandardMaterial3D = StandardMaterial3D.new()
	mat_orange.albedo_color = Color(1.0, 0.45, 0.0)
	bill.material_override = mat_orange
	visual_mesh.add_child(bill)

	# Eyes
	for side in [-1.0, 1.0]:
		var eye: MeshInstance3D = MeshInstance3D.new()
		var es: SphereMesh = SphereMesh.new()
		es.radius = 0.04
		es.height = 0.08
		eye.mesh = es
		eye.position = Vector3(side * 0.14, 0.35, 0.34)
		var mat_dark: StandardMaterial3D = StandardMaterial3D.new()
		mat_dark.albedo_color = Color(0.1, 0.1, 0.15)
		eye.material_override = mat_dark
		visual_mesh.add_child(eye)

func _create_crate_mesh() -> void:
	# Check if imported GLB exists
	var crate_path: String = "res://assets/models/props/gift_crate.glb"
	if ResourceLoader.exists(crate_path):
		var scn: PackedScene = load(crate_path)
		var inst = scn.instantiate()
		inst.scale = Vector3(0.35, 0.35, 0.35)
		add_child(inst)
		visual_mesh = inst
	else:
		# Procedural wooden crate
		visual_mesh = Node3D.new()
		add_child(visual_mesh)
		var c: MeshInstance3D = MeshInstance3D.new()
		var b: BoxMesh = BoxMesh.new()
		b.size = Vector3(0.65, 0.65, 0.65)
		c.mesh = b
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.albedo_color = Color(0.62, 0.42, 0.24)
		mat.roughness = 0.7
		c.material_override = mat
		visual_mesh.add_child(c)

func _create_anchor_mesh() -> void:
	visual_mesh = Node3D.new()
	add_child(visual_mesh)

	var mat_iron: StandardMaterial3D = StandardMaterial3D.new()
	mat_iron.albedo_color = Color(0.2, 0.22, 0.26)
	mat_iron.metallic = 0.85
	mat_iron.roughness = 0.35

	# Central Shank
	var shank: MeshInstance3D = MeshInstance3D.new()
	var cyl: CylinderMesh = CylinderMesh.new()
	cyl.top_radius = 0.08
	cyl.bottom_radius = 0.08
	cyl.height = 0.8
	shank.mesh = cyl
	shank.material_override = mat_iron
	visual_mesh.add_child(shank)

	# Cross Stock
	var stock: MeshInstance3D = MeshInstance3D.new()
	var b: BoxMesh = BoxMesh.new()
	b.size = Vector3(0.65, 0.06, 0.06)
	stock.mesh = b
	stock.position = Vector3(0, 0.26, 0)
	stock.material_override = mat_iron
	visual_mesh.add_child(stock)

	# Ring at the shank head. Without it the silhouette reads as a plain "T" from the
	# game camera, which is not enough to tell an anchor from the other props.
	var ring: MeshInstance3D = MeshInstance3D.new()
	var torus: TorusMesh = TorusMesh.new()
	torus.inner_radius = 0.06
	torus.outer_radius = 0.13
	torus.rings = 10
	torus.ring_segments = 12 # ~10 px on screen: the default 64x32 is wasted geometry
	ring.mesh = torus
	ring.position = Vector3(0, 0.47, 0)
	ring.rotation_degrees = Vector3(90, 0, 0)
	ring.material_override = mat_iron
	visual_mesh.add_child(ring)

	# Base Flukes Curved Bar
	var fluke: MeshInstance3D = MeshInstance3D.new()
	var fb: BoxMesh = BoxMesh.new()
	fb.size = Vector3(0.6, 0.12, 0.14)
	fluke.mesh = fb
	fluke.position = Vector3(0, -0.35, 0)
	fluke.material_override = mat_iron
	visual_mesh.add_child(fluke)

func _create_mascot_mesh() -> void:
	var mascot_path: String = "res://assets/models/characters/streamer_mascot.glb"
	if ResourceLoader.exists(mascot_path):
		var scn: PackedScene = load(mascot_path)
		var inst = scn.instantiate()
		inst.scale = Vector3(0.35, 0.35, 0.35)
		add_child(inst)
		visual_mesh = inst
	else:
		# Procedural cute capsule mascot
		visual_mesh = Node3D.new()
		add_child(visual_mesh)
		var cap: MeshInstance3D = MeshInstance3D.new()
		var cm: CapsuleMesh = CapsuleMesh.new()
		cm.radius = 0.25
		cm.height = 0.8
		cap.mesh = cm
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.albedo_color = Color(0.85, 0.3, 0.85)
		cap.material_override = mat
		visual_mesh.add_child(cap)
