class_name GameManager
extends Node3D

## Coordinates 3D Heightfield Terrain, Shallow Water Simulation, Arcade Controls,
## Stream Ingestion Hazards, and Game Juice.

const SPILL_THRESHOLD: float = 35.0 # Liters before earthquake triggers
const TICK_RATE: float = 1.0 / 30.0 # 30Hz fluid sim step
const MAX_SIM_STEPS_PER_FRAME: int = 4 # catch-up cap: one long frame must not spiral
const WATER_CAPACITY: float = 1228.8 # 32x32 cells at 1.2 depth: the arena completely awash
const ABILITY_COOLDOWNS: Array[float] = [10.0, 4.0, 12.0]

@onready var terrain_mesh_instance: MeshInstance3D = $Arena/TerrainMeshInstance
@onready var water_mesh_instance: MeshInstance3D = $Arena/WaterMeshInstance
@onready var cursor_root: Node3D = $Arena/CursorRoot
@onready var prop_manager: PropManager = $Arena/PropManager
@onready var camera_pivot: Node3D = $CameraPivot
@onready var camera_3d: Camera3D = $CameraPivot/Camera3D
@onready var hud: GameHUD = $GameHUD
@onready var stream_events: StreamEventManager = $StreamEventManager

# Simulation & Builders
var sim: FluidSim
var terrain_builder: TerrainMeshBuilder
var water_builder: WaterMeshBuilder
var piece_manager: PieceManager

# Materials
var terrain_material: ShaderMaterial
var water_material: ShaderMaterial

# Cursor & Placement
var cursor_grid_pos: Vector2i = Vector2i(16, 16)
var cursor_blocks: Array[MeshInstance3D] = []

# Game State
var score: int = 0
var multiplier: float = 1.0
var combo_timer: float = 0.0
var sim_accum: float = 0.0
var screen_shake_intensity: float = 0.0
var is_frozen: bool = false
var freeze_timer: float = 0.0
var ability_cooldowns: Array[float] = [0.0, 0.0, 0.0]
var water_mesh_revision: int = -1
var sim_steps_last_frame: int = 0

func _ready() -> void:
	_init_simulation()
	_init_cursor_pool()
	_init_event_listeners()
	_update_cursor_visuals()
	hud.update_queue_display(piece_manager.queue)
	hud.update_score(score, multiplier)

func _init_simulation() -> void:
	sim = FluidSim.new()
	piece_manager = PieceManager.new()

	terrain_material = ShaderMaterial.new()
	terrain_material.shader = load("res://assets/shaders/terrain.gdshader")

	water_material = ShaderMaterial.new()
	water_material.shader = load("res://assets/shaders/water.gdshader")

	terrain_builder = TerrainMeshBuilder.new(terrain_material)
	water_builder = WaterMeshBuilder.new(water_material)
	prop_manager.setup(sim)

	# Initial flat island with starter walls around the center
	for y in range(FluidSim.GRID_SIZE):
		for x in range(FluidSim.GRID_SIZE):
			# Base elevation of 1.0
			sim.set_terrain(x, y, 1.0)

	# Build a starter reservoir in the center
	for i in range(12, 20):
		sim.set_terrain(i, 11, 2.5)
		sim.set_terrain(i, 20, 2.5)
		sim.set_terrain(11, i, 2.5)
		sim.set_terrain(20, i, 2.5)

	# Add starter water inside the reservoir
	for y in range(13, 19):
		for x in range(13, 19):
			sim.add_water(x, y, 1.2)

	rebuild_terrain()
	rebuild_water()

func _init_cursor_pool() -> void:
	# Pool up to 16 cursor cubes for polyomino previews
	for i in range(16):
		var mesh_inst: MeshInstance3D = MeshInstance3D.new()
		var box: BoxMesh = BoxMesh.new()
		box.size = Vector3(0.95, 0.4, 0.95)
		mesh_inst.mesh = box

		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.2, 0.9, 0.3, 0.75)
		mat.emission_enabled = true
		mat.emission = Color(0.2, 0.9, 0.3)
		mat.emission_energy_multiplier = 0.5
		mesh_inst.material_override = mat

		cursor_root.add_child(mesh_inst)
		cursor_blocks.append(mesh_inst)

func _init_event_listeners() -> void:
	stream_events.stream_action_received.connect(_on_stream_action)
	stream_events.alert_announcement.connect(_on_stream_alert)
	hud.toggle_aspect_ratio_requested.connect(_on_toggle_aspect_ratio)
	hud.ability_triggered.connect(_on_ability_triggered)
	hud.simulate_event_clicked.connect(_on_sim_event_clicked)
	prop_manager.prop_vaporized_in_steam.connect(_on_prop_vaporized)
	prop_manager.prop_plunged.connect(_on_prop_plunged)

func _process(delta: float) -> void:
	_handle_input(delta)
	_handle_camera_shake(delta)
	_handle_combo_decay(delta)
	_handle_freeze(delta)
	_handle_ability_cooldowns(delta)

	# Fluid simulation stepped at fixed tick rate, with a per-frame catch-up cap. Without
	# it a single long frame (a stream hitch, a shader compile) asks for a dozen steps,
	# which makes the next frame longer still and the sim never catches up.
	sim_steps_last_frame = 0
	if not is_frozen:
		sim_accum += delta
		while sim_accum >= TICK_RATE and sim_steps_last_frame < MAX_SIM_STEPS_PER_FRAME:
			sim.step(TICK_RATE)
			sim_accum -= TICK_RATE
			sim_steps_last_frame += 1
		# Drop whole ticks we could not afford this frame: keep at most one tick of
		# remainder so the sim runs slightly slow after a hitch instead of banking debt.
		if sim_accum > TICK_RATE:
			sim_accum = TICK_RATE

	# Rebuilds only when the simulation revision moved (see rebuild_water)
	rebuild_water()

	# Update HUD telemetry
	hud.update_water_stats(sim.active_water_volume, WATER_CAPACITY)
	hud.update_drain_meter(sim.total_spilled_water, SPILL_THRESHOLD)
	hud.update_ability_cooldowns(ability_cooldowns)

	# Earthquake check on spilled threshold
	if sim.total_spilled_water >= SPILL_THRESHOLD:
		_trigger_earthquake()

func _handle_input(_delta: float) -> void:
	var moved: bool = false
	if Input.is_action_just_pressed("move_left"):
		cursor_grid_pos.x = clampi(cursor_grid_pos.x - 1, 1, FluidSim.GRID_SIZE - 2)
		moved = true
	if Input.is_action_just_pressed("move_right"):
		cursor_grid_pos.x = clampi(cursor_grid_pos.x + 1, 1, FluidSim.GRID_SIZE - 2)
		moved = true
	if Input.is_action_just_pressed("move_up"):
		cursor_grid_pos.y = clampi(cursor_grid_pos.y - 1, 1, FluidSim.GRID_SIZE - 2)
		moved = true
	if Input.is_action_just_pressed("move_down"):
		cursor_grid_pos.y = clampi(cursor_grid_pos.y + 1, 1, FluidSim.GRID_SIZE - 2)
		moved = true

	if Input.is_action_just_pressed("rotate_piece"):
		piece_manager.rotate_clockwise()
		_update_cursor_visuals()

	if Input.is_action_just_pressed("drop_piece"):
		_apply_current_piece()

	if Input.is_action_just_pressed("toggle_orientation"):
		hud.toggle_orientation()

	if Input.is_action_just_pressed("ability_1"):
		_on_ability_triggered(1)
	if Input.is_action_just_pressed("ability_2"):
		_on_ability_triggered(2)
	if Input.is_action_just_pressed("ability_3"):
		_on_ability_triggered(3)

	if Input.is_action_just_pressed("ui_focus_next"): # Tab for simulated bit donation
		stream_events.simulate_twitch_event("TwitchFan_" + str(randi() % 99), 100)

	if moved:
		_update_cursor_visuals()

func _update_cursor_visuals() -> void:
	var piece: PieceManager.PieceData = piece_manager.current_piece
	if not piece:
		return

	var cells: Array[Vector2i] = piece_manager.get_current_cells()
	var half: float = FluidSim.GRID_SIZE * 0.5

	for i in range(cursor_blocks.size()):
		var block: MeshInstance3D = cursor_blocks[i]
		if i < cells.size():
			var c: Vector2i = cells[i]
			var gx: int = cursor_grid_pos.x + c.x
			var gy: int = cursor_grid_pos.y + c.y
			var valid: bool = sim.is_in_bounds(gx, gy)

			block.visible = valid
			if valid:
				var h: float = sim.get_terrain(gx, gy) + sim.get_water(gx, gy)
				block.position = Vector3(float(gx) - half + 0.5, h + 0.35, float(gy) - half + 0.5)

				var mat: StandardMaterial3D = block.material_override
				mat.albedo_color = piece.color
				mat.albedo_color.a = 0.75
				mat.emission = piece.color
		else:
			block.visible = false

func _apply_current_piece() -> void:
	var piece: PieceManager.PieceData = piece_manager.current_piece
	if not piece:
		return

	var cells: Array[Vector2i] = piece_manager.get_current_cells()
	var terrain_dirty: bool = false

	match piece.type:
		PieceManager.PieceType.UPPER:
			for c in cells:
				var gx: int = cursor_grid_pos.x + c.x
				var gy: int = cursor_grid_pos.y + c.y
				sim.add_terrain(gx, gy, piece.power)
			terrain_dirty = true
			add_shake(0.12)

		PieceManager.PieceType.DOWNER:
			for c in cells:
				var gx: int = cursor_grid_pos.x + c.x
				var gy: int = cursor_grid_pos.y + c.y
				sim.add_terrain(gx, gy, piece.power)
			terrain_dirty = true
			add_shake(0.15)

		PieceManager.PieceType.WATER_DROP:
			for c in cells:
				var gx: int = cursor_grid_pos.x + c.x
				var gy: int = cursor_grid_pos.y + c.y
				sim.add_water(gx, gy, piece.power)
			add_shake(0.08)

		PieceManager.PieceType.FIREBALL:
			# Evaporate water in 3x3 radius
			var evap_amount: float = sim.evaporate_at(cursor_grid_pos.x, cursor_grid_pos.y, 2, piece.power)
			if evap_amount > 0.05:
				_award_evap_score(evap_amount)
				add_shake(0.25)
			else:
				# Missed water: scorches ground slightly
				sim.add_terrain(cursor_grid_pos.x, cursor_grid_pos.y, -0.3)
				terrain_dirty = true

		PieceManager.PieceType.BOMB:
			# Crater
			sim.add_terrain(cursor_grid_pos.x, cursor_grid_pos.y, -piece.power)
			sim.evaporate_at(cursor_grid_pos.x, cursor_grid_pos.y, 2, 2.0)
			terrain_dirty = true
			add_shake(0.4)

		PieceManager.PieceType.SPONGE:
			sim.evaporate_at(cursor_grid_pos.x, cursor_grid_pos.y, 3, piece.power * 2.0)
			add_shake(0.1)

	if terrain_dirty:
		rebuild_terrain()

	# Next piece
	piece_manager.advance_queue()
	hud.update_queue_display(piece_manager.queue)
	_update_cursor_visuals()

func _award_evap_score(evap_vol: float) -> void:
	multiplier += 0.25
	combo_timer = 5.0
	var points: int = int(evap_vol * 100.0 * multiplier)
	
	# Check for props boiled in the steam
	var prop_bonus: int = prop_manager.check_evaporate_props_in_radius(cursor_grid_pos.x, cursor_grid_pos.y, 2)
	points += prop_bonus
	
	score += points
	hud.update_score(score, multiplier)
	hud.show_alert("STEAM EVAPORATION!", "+" + str(points) + " Points! (x" + str(snappedf(multiplier, 0.1)) + ")", Color(1.0, 0.4, 0.1))

func _handle_combo_decay(delta: float) -> void:
	if combo_timer > 0.0:
		combo_timer -= delta
		if combo_timer <= 0.0:
			multiplier = 1.0
			hud.update_score(score, multiplier)

func _handle_freeze(delta: float) -> void:
	if is_frozen:
		freeze_timer -= delta
		if freeze_timer <= 0.0:
			is_frozen = false
			hud.show_alert("ICE MELTED", "Liquids are flowing again!", Color(0.2, 0.7, 1.0))

func _handle_ability_cooldowns(delta: float) -> void:
	for i in range(ability_cooldowns.size()):
		if ability_cooldowns[i] > 0.0:
			ability_cooldowns[i] = maxf(0.0, ability_cooldowns[i] - delta)

func _trigger_earthquake() -> void:
	hud.show_alert("EARTHQUAKE DISASTER!", "Drain exceeded! Arena collapsing!", Color(1.0, 0.1, 0.1))
	add_shake(0.85)

	# Shatter 3 random wall cells
	for i in range(8):
		var rx: int = randi_range(6, FluidSim.GRID_SIZE - 7)
		var ry: int = randi_range(6, FluidSim.GRID_SIZE - 7)
		sim.add_terrain(rx, ry, -1.8)

	sim.total_spilled_water = 0.0
	rebuild_terrain()

func _on_stream_action(donor: String, action: String, val: int, _platform: String) -> void:
	var half: float = float(FluidSim.GRID_SIZE) * 0.5
	match action:
		"DUCK_SPLASH":
			var rx: int = randi_range(8, FluidSim.GRID_SIZE - 9)
			var ry: int = randi_range(8, FluidSim.GRID_SIZE - 9)
			sim.add_water(rx, ry, 1.5)
			var spawn_pos: Vector3 = Vector3(float(rx) - half + 0.5, 3.0, float(ry) - half + 0.5)
			prop_manager.spawn_prop(FloatingProp.PropClass.RUBBER_DUCK, donor, "Rose", val, spawn_pos)
			add_shake(0.08)
		"WALL_BLESSING":
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					sim.add_terrain(cursor_grid_pos.x + dx, cursor_grid_pos.y + dy, 0.8)
			rebuild_terrain()
			add_shake(0.15)
		"WATER_BOMB":
			var rx: int = randi_range(6, FluidSim.GRID_SIZE - 7)
			var ry: int = randi_range(6, FluidSim.GRID_SIZE - 7)
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					sim.add_water(rx + dx, ry + dy, 2.5)
			var spawn_pos: Vector3 = Vector3(float(rx) - half + 0.5, 4.0, float(ry) - half + 0.5)
			prop_manager.spawn_prop(FloatingProp.PropClass.GIFT_CRATE, donor, "Doughnut", val, spawn_pos)
			add_shake(0.3)
		"TSUNAMI":
			var row: int = randi_range(4, FluidSim.GRID_SIZE - 5)
			for x in range(2, FluidSim.GRID_SIZE - 2):
				sim.add_water(x, row, 3.5)
			var spawn_pos: Vector3 = Vector3(0.0, 3.5, float(row) - half + 0.5)
			prop_manager.spawn_prop(FloatingProp.PropClass.STREAMER_MASCOT, donor, "Galaxy", val, spawn_pos)
			add_shake(0.55)
		"VOLCANO_BOMB":
			var rx: int = randi_range(8, FluidSim.GRID_SIZE - 9)
			var ry: int = randi_range(8, FluidSim.GRID_SIZE - 9)
			for dy in range(-2, 3):
				for dx in range(-2, 3):
					sim.add_terrain(rx + dx, ry + dy, -1.5)
			var spawn_pos: Vector3 = Vector3(float(rx) - half + 0.5, 5.0, float(ry) - half + 0.5)
			prop_manager.spawn_prop(FloatingProp.PropClass.HEAVY_ANCHOR, donor, "Lion", val, spawn_pos)
			rebuild_terrain()
			add_shake(0.7)
		"FLASH_FREEZE":
			is_frozen = true
			freeze_timer = 6.0
			add_shake(0.1)
		"SPONGE_RESCUE":
			sim.evaporate_at(cursor_grid_pos.x, cursor_grid_pos.y, 4, 6.0)
			add_shake(0.12)

	rebuild_water()

func _on_prop_vaporized(prop_name: String, donor: String, bonus_pts: int) -> void:
	hud.show_alert(prop_name.to_upper() + " BOILED!", donor + "'s gift vaporized! +" + str(bonus_pts) + " PTS!", Color(1.0, 0.8, 0.2))
	add_shake(0.2)

func _on_prop_plunged(prop_name: String, donor: String) -> void:
	hud.show_alert("WATERFALL PLUNGE!", "RIP " + donor + "'s " + prop_name + " fell off the edge!", Color(0.9, 0.2, 0.3))
	add_shake(0.15)

func _on_stream_alert(title: String, subtitle: String, color: Color) -> void:
	hud.show_alert(title, subtitle, color)
	hud.update_vip(stream_events.highest_single_donor, stream_events.highest_single_amount)

func _on_ability_triggered(ability_id: int) -> void:
	var idx: int = ability_id - 1
	if idx < 0 or idx >= ability_cooldowns.size():
		return
	if ability_cooldowns[idx] > 0.0:
		hud.show_alert("ABILITY RECHARGING", "Ready in " + str(snappedf(ability_cooldowns[idx], 0.1)) + "s", Color(0.6, 0.65, 0.7))
		return

	match ability_id:
		1: # Flash Freeze
			is_frozen = true
			freeze_timer = 6.0
			hud.show_alert("FLASH FREEZE ACTIVATED", "6 seconds of liquid stasis!", Color(0.3, 0.9, 1.0))
		2: # Solar Ray
			var evap: float = sim.evaporate_at(cursor_grid_pos.x, cursor_grid_pos.y, 3, 5.0)
			if evap > 0.05:
				_award_evap_score(evap)
			else:
				hud.show_alert("SOLAR RAY MISSED", "Aim at standing water to boil it off.", Color(1.0, 0.6, 0.2))
			add_shake(0.2)
		3: # Seismic Anchor
			for dy in range(-2, 3):
				for dx in range(-2, 3):
					sim.add_terrain(cursor_grid_pos.x + dx, cursor_grid_pos.y + dy, 1.0)
			rebuild_terrain()
			hud.show_alert("SEISMIC ANCHOR", "Reinforced dams!", Color(0.3, 0.9, 0.4))

	ability_cooldowns[idx] = ABILITY_COOLDOWNS[idx]

func _on_sim_event_clicked(event_type: String) -> void:
	match event_type:
		"bits_100":
			stream_events.simulate_twitch_event("Viewer_" + str(randi() % 99), 100)
		"bits_500":
			stream_events.simulate_twitch_event("ChadBits", 500)
		"bits_1000":
			stream_events.simulate_twitch_event("GigaWhale", 1000)
		"tiktok_rose":
			stream_events.simulate_tiktok_gift("TiktokFan", "rose", 1)
		"tiktok_galaxy":
			stream_events.simulate_tiktok_gift("StarGazer", "galaxy", 500)
		"tiktok_lion":
			stream_events.simulate_tiktok_gift("KingLion", "lion", 1000)

func _on_toggle_aspect_ratio() -> void:
	var vp_size: Vector2 = get_viewport().get_visible_rect().size
	if hud.is_vertical_mode:
		# TikTok 9:16 vertical view: Pull camera back and increase FOV
		camera_3d.fov = 68.0
		camera_pivot.position = Vector3(0, 18.0, 18.0)
		hud.show_alert("VERTICAL MODE (9:16)", "Optimal for TikTok Live stream!", Color(0.9, 0.2, 0.8))
	else:
		# Standard 16:9 widescreen view
		camera_3d.fov = 52.0
		camera_pivot.position = Vector3(0, 14.0, 14.0)
		hud.show_alert("WIDESCREEN MODE (16:9)", "Standard landscape streaming!", Color(0.2, 0.7, 1.0))

func add_shake(amount: float) -> void:
	screen_shake_intensity = clampf(screen_shake_intensity + amount, 0.0, 1.0)

func _handle_camera_shake(delta: float) -> void:
	if screen_shake_intensity > 0.001:
		var offset: Vector3 = Vector3(
			randf_range(-1.0, 1.0) * screen_shake_intensity * 0.7,
			randf_range(-1.0, 1.0) * screen_shake_intensity * 0.4,
			randf_range(-1.0, 1.0) * screen_shake_intensity * 0.7
		)
		camera_3d.position = offset
		screen_shake_intensity = lerpf(screen_shake_intensity, 0.0, delta * 7.0)
	else:
		camera_3d.position = Vector3.ZERO

func rebuild_terrain() -> void:
	terrain_mesh_instance.mesh = terrain_builder.build_mesh(sim)

func rebuild_water(force: bool = false) -> void:
	if not force and sim.water_revision == water_mesh_revision:
		return
	water_mesh_revision = sim.water_revision
	water_mesh_instance.mesh = water_builder.build_mesh(sim)
