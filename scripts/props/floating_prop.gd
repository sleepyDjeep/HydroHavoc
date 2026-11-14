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

func _ready() -> void:
	rocking_seed = randf() * 100.0
	_build_visuals()
	_build_nameplate()

func setup(p_sim: FluidSim, p_class: PropClass, p_donor: String, p_tier: String, p_val: int) -> void:
	fluid_sim = p_sim
	prop_class = p_class
	donor_name = p_donor
	gift_tier = p_tier
	gift_value = p_val
	if nameplate_label:
		nameplate_label.text = "👑 " + donor_name + "\n[" + gift_tier + "]"

func _process(delta: float) -> void:
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
	nameplate_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	nameplate_label.font_size = 24
	nameplate_label.pixel_size = 0.005
	nameplate_label.outline_size = 6
	nameplate_label.outline_modulate = Color(0.05, 0.05, 0.1, 0.95)
	nameplate_label.position = Vector3(0, 1.1, 0)
	nameplate_label.text = "👑 " + donor_name + "\n[" + gift_tier + "]"
	nameplate_label.modulate = _get_tier_color()
	add_child(nameplate_label)

func _get_tier_color() -> Color:
	match prop_class:
		PropClass.RUBBER_DUCK:
			return Color(1.0, 0.9, 0.2)
		PropClass.GIFT_CRATE:
			return Color(0.4, 0.9, 1.0)
		PropClass.HEAVY_ANCHOR:
			return Color(1.0, 0.3, 0.4)
		PropClass.STREAMER_MASCOT:
			return Color(0.9, 0.4, 1.0)
		_:
			return Color.WHITE

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
	b.size = Vector3(0.65, 0.09, 0.09)
	stock.mesh = b
	stock.position = Vector3(0, 0.26, 0)
	stock.material_override = mat_iron
	visual_mesh.add_child(stock)

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
