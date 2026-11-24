class_name FluidSim
extends RefCounted

## 2.5D Shallow Water Equations (Virtual Pipe Model) on a Heightfield Grid
## Designed for ultra-high performance in Godot 4.7 with zero dropped frames.

const GRID_SIZE: int = 32
const CELL_COUNT: int = GRID_SIZE * GRID_SIZE
const CELL_SIZE: float = 1.0 # 1 meter per cell
const GRAVITY: float = 9.8
const PIPE_AREA: float = 0.5
const DAMPING: float = 0.985 # Viscosity damping
const MIN_WATER_DISPLAY: float = 0.02

# Heightfields stored as flat 1D arrays for SIMD cache friendliness
var terrain: PackedFloat32Array
var water: PackedFloat32Array

# Flux pipes: 4 directional fluxes per cell (0: North, 1: South, 2: East, 3: West)
var flux_n: PackedFloat32Array
var flux_s: PackedFloat32Array
var flux_e: PackedFloat32Array
var flux_w: PackedFloat32Array

# Spill tracking
var total_spilled_water: float = 0.0
var spill_rate: float = 0.0
var active_water_volume: float = 0.0

# Cumulative bookkeeping. Water only enters through add_water() and only leaves through
# evaporate_at() or the rim, so
#   total_added - total_evaporated - total_drained == active_water_volume
# must hold. tests/sim_invariants.gd asserts exactly that. total_drained is deliberately
# separate from total_spilled_water: the latter is the drain meter the earthquake resets,
# so using it here would erase the spill from the ledger every 35 L.
var total_added_water: float = 0.0
var total_evaporated_water: float = 0.0
var total_drained_water: float = 0.0

# Monotonic counter bumped whenever terrain or water changes. Consumers that derive
# geometry from the field (the water mesh) use it to skip redundant rebuilds.
var water_revision: int = 0

func _init() -> void:
	terrain.resize(CELL_COUNT)
	water.resize(CELL_COUNT)
	flux_n.resize(CELL_COUNT)
	flux_s.resize(CELL_COUNT)
	flux_e.resize(CELL_COUNT)
	flux_w.resize(CELL_COUNT)
	reset()

func reset() -> void:
	total_spilled_water = 0.0
	spill_rate = 0.0
	active_water_volume = 0.0
	total_added_water = 0.0
	total_evaporated_water = 0.0
	total_drained_water = 0.0
	water_revision += 1
	for i in range(CELL_COUNT):
		terrain[i] = 0.0
		water[i] = 0.0
		flux_n[i] = 0.0
		flux_s[i] = 0.0
		flux_e[i] = 0.0
		flux_w[i] = 0.0

func get_index(x: int, y: int) -> int:
	return y * GRID_SIZE + x

func is_in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < GRID_SIZE and y >= 0 and y < GRID_SIZE

func get_terrain(x: int, y: int) -> float:
	if not is_in_bounds(x, y):
		return 0.0
	return terrain[get_index(x, y)]

func set_terrain(x: int, y: int, height: float) -> void:
	if is_in_bounds(x, y):
		terrain[get_index(x, y)] = maxf(0.0, height)
		water_revision += 1

func add_terrain(x: int, y: int, delta: float) -> void:
	if is_in_bounds(x, y):
		var idx: int = get_index(x, y)
		terrain[idx] = clampf(terrain[idx] + delta, 0.0, 15.0)
		water_revision += 1

func get_water(x: int, y: int) -> float:
	if not is_in_bounds(x, y):
		return 0.0
	return water[get_index(x, y)]

func add_water(x: int, y: int, volume: float) -> void:
	if is_in_bounds(x, y):
		var idx: int = get_index(x, y)
		var before: float = water[idx]
		water[idx] = maxf(0.0, before + volume)
		total_added_water += water[idx] - before
		water_revision += 1

func evaporate_at(center_x: int, center_y: int, radius: int, max_evap: float) -> float:
	var total_evaporated: float = 0.0
	var r2: int = radius * radius
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if dx * dx + dy * dy <= r2:
				var gx: int = center_x + dx
				var gy: int = center_y + dy
				if is_in_bounds(gx, gy):
					var idx: int = get_index(gx, gy)
					var w: float = water[idx]
					if w > 0.0:
						var removed: float = minf(w, max_evap)
						water[idx] -= removed
						total_evaporated += removed
	if total_evaporated > 0.0:
		total_evaporated_water += total_evaporated
		water_revision += 1
	return total_evaporated

func get_water_height_at_world_pos(world_x: float, world_z: float) -> float:
	var half: float = GRID_SIZE * 0.5
	var gx: int = clampi(int(floor(world_x + half)), 0, GRID_SIZE - 1)
	var gz: int = clampi(int(floor(world_z + half)), 0, GRID_SIZE - 1)
	var idx: int = get_index(gx, gz)
	return terrain[idx] + water[idx]

func get_water_depth_at_world_pos(world_x: float, world_z: float) -> float:
	var half: float = GRID_SIZE * 0.5
	var gx: int = int(floor(world_x + half))
	var gz: int = int(floor(world_z + half))
	if not is_in_bounds(gx, gz):
		return 0.0
	return water[get_index(gx, gz)]

func get_fluid_velocity_at_world_pos(world_x: float, world_z: float) -> Vector2:
	var half: float = GRID_SIZE * 0.5
	var gx: int = int(floor(world_x + half))
	var gz: int = int(floor(world_z + half))
	if not is_in_bounds(gx, gz):
		return Vector2.ZERO

	var idx: int = get_index(gx, gz)
	var w: float = water[idx]
	if w <= 0.01:
		return Vector2.ZERO

	# Horizontal flux velocities
	var vx: float = (flux_e[idx] - flux_w[idx]) / maxf(w, 0.5)
	var vz: float = (flux_s[idx] - flux_n[idx]) / maxf(w, 0.5)
	return Vector2(vx, vz)

func inject_splash_wave(world_x: float, world_z: float, volume: float) -> void:
	var half: float = GRID_SIZE * 0.5
	var cx: int = int(floor(world_x + half))
	var cz: int = int(floor(world_z + half))
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var gx: int = cx + dx
			var gz: int = cz + dy
			if is_in_bounds(gx, gz):
				var factor: float = 1.0 if (dx == 0 and dy == 0) else 0.5
				add_water(gx, gz, volume * factor)

func step(dt: float) -> void:
	dt = minf(dt, 0.033) # Clamp physics sub-step
	var current_step_spill: float = 0.0
	var current_active_vol: float = 0.0
	var field_motion: float = 0.0

	# Step 1: Outflow flux computation for each cell
	for y in range(GRID_SIZE):
		for x in range(GRID_SIZE):
			var idx: int = get_index(x, y)
			var w_src: float = water[idx]
			if w_src <= 0.0001:
				flux_n[idx] = 0.0
				flux_s[idx] = 0.0
				flux_e[idx] = 0.0
				flux_w[idx] = 0.0
				continue

			var h_src: float = terrain[idx] + w_src

			# North (y - 1)
			var h_n: float = 0.0
			var is_edge_n: bool = (y == 0)
			if not is_edge_n:
				var idx_n: int = get_index(x, y - 1)
				h_n = terrain[idx_n] + water[idx_n]
			var delta_h_n: float = h_src - h_n
			flux_n[idx] = maxf(0.0, (flux_n[idx] + dt * PIPE_AREA * GRAVITY * delta_h_n) * DAMPING)

			# South (y + 1)
			var h_s: float = 0.0
			var is_edge_s: bool = (y == GRID_SIZE - 1)
			if not is_edge_s:
				var idx_s: int = get_index(x, y + 1)
				h_s = terrain[idx_s] + water[idx_s]
			var delta_h_s: float = h_src - h_s
			flux_s[idx] = maxf(0.0, (flux_s[idx] + dt * PIPE_AREA * GRAVITY * delta_h_s) * DAMPING)

			# East (x + 1)
			var h_e: float = 0.0
			var is_edge_e: bool = (x == GRID_SIZE - 1)
			if not is_edge_e:
				var idx_e: int = get_index(x + 1, y)
				h_e = terrain[idx_e] + water[idx_e]
			var delta_h_e: float = h_src - h_e
			flux_e[idx] = maxf(0.0, (flux_e[idx] + dt * PIPE_AREA * GRAVITY * delta_h_e) * DAMPING)

			# West (x - 1)
			var h_w: float = 0.0
			var is_edge_w: bool = (x == 0)
			if not is_edge_w:
				var idx_w: int = get_index(x - 1, y)
				h_w = terrain[idx_w] + water[idx_w]
			var delta_h_w: float = h_src - h_w
			flux_w[idx] = maxf(0.0, (flux_w[idx] + dt * PIPE_AREA * GRAVITY * delta_h_w) * DAMPING)

			# Scaling factor K to guarantee mass conservation (cannot outflow more than available water)
			var total_outflow: float = (flux_n[idx] + flux_s[idx] + flux_e[idx] + flux_w[idx]) * dt
			if total_outflow > w_src and total_outflow > 0.0:
				var k: float = w_src / total_outflow
				flux_n[idx] *= k
				flux_s[idx] *= k
				flux_e[idx] *= k
				flux_w[idx] *= k

	# Step 2: Update water heights from flux exchange
	for y in range(GRID_SIZE):
		for x in range(GRID_SIZE):
			var idx: int = get_index(x, y)

			# Inflows from neighbors
			var in_n: float = flux_s[get_index(x, y - 1)] if y > 0 else 0.0
			var in_s: float = flux_n[get_index(x, y + 1)] if y < GRID_SIZE - 1 else 0.0
			var in_w: float = flux_e[get_index(x - 1, y)] if x > 0 else 0.0
			var in_e: float = flux_w[get_index(x + 1, y)] if x < GRID_SIZE - 1 else 0.0

			var sum_in: float = in_n + in_s + in_w + in_e
			var sum_out: float = flux_n[idx] + flux_s[idx] + flux_e[idx] + flux_w[idx]

			# Perimeter spillage over edge boundaries
			if y == 0:
				current_step_spill += flux_n[idx] * dt
			if y == GRID_SIZE - 1:
				current_step_spill += flux_s[idx] * dt
			if x == 0:
				current_step_spill += flux_w[idx] * dt
			if x == GRID_SIZE - 1:
				current_step_spill += flux_e[idx] * dt

			var new_w: float = water[idx] + dt * (sum_in - sum_out)
			water[idx] = maxf(0.0, new_w)
			current_active_vol += water[idx]
			field_motion += absf(sum_in - sum_out)

	total_spilled_water += current_step_spill
	total_drained_water += current_step_spill
	spill_rate = current_step_spill / dt
	active_water_volume = current_active_vol

	# A settled mixture nets to zero per-cell change, so the surface mesh can keep its
	# previous geometry. Only a field that actually moved invalidates it.
	if field_motion > 0.0005:
		water_revision += 1
