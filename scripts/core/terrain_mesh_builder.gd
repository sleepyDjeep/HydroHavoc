class_name TerrainMeshBuilder
extends RefCounted

## Generates and updates the 3D terrain island mesh from the heightfield grid.

const GRID_SIZE: int = FluidSim.GRID_SIZE
const HALF_GRID: float = GRID_SIZE * 0.5
const SKIRT_DEPTH: float = 4.0

var surface_tool: SurfaceTool
var terrain_material: ShaderMaterial

func _init(material: ShaderMaterial = null) -> void:
	surface_tool = SurfaceTool.new()
	terrain_material = material

func build_mesh(sim: FluidSim) -> ArrayMesh:
	surface_tool.clear()
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)

	var vert_count_axis: int = GRID_SIZE + 1

	# Helper to compute vertex height at corner (x, z) by averaging neighboring cells
	var get_corner_height = func(cx: int, cz: int) -> float:
		var sum: float = 0.0
		var count: int = 0
		for dy in range(-1, 1):
			for dx in range(-1, 1):
				var sample_x: int = cx + dx
				var sample_y: int = cz + dy
				if sim.is_in_bounds(sample_x, sample_y):
					sum += sim.get_terrain(sample_x, sample_y)
					count += 1
		return sum / float(max(count, 1))

	# Precompute vertex positions, UVs, and normals
	var corner_heights: PackedFloat32Array = PackedFloat32Array()
	corner_heights.resize(vert_count_axis * vert_count_axis)

	for cz in range(vert_count_axis):
		for cx in range(vert_count_axis):
			var idx: int = cz * vert_count_axis + cx
			corner_heights[idx] = get_corner_height.call(cx, cz)

	# Generate top terrain surface quads
	for z in range(GRID_SIZE):
		for x in range(GRID_SIZE):
			var p00_idx: int = z * vert_count_axis + x
			var p10_idx: int = z * vert_count_axis + (x + 1)
			var p01_idx: int = (z + 1) * vert_count_axis + x
			var p11_idx: int = (z + 1) * vert_count_axis + (x + 1)

			var v00: Vector3 = Vector3(float(x) - HALF_GRID, corner_heights[p00_idx], float(z) - HALF_GRID)
			var v10: Vector3 = Vector3(float(x + 1) - HALF_GRID, corner_heights[p10_idx], float(z) - HALF_GRID)
			var v01: Vector3 = Vector3(float(x) - HALF_GRID, corner_heights[p01_idx], float(z + 1) - HALF_GRID)
			var v11: Vector3 = Vector3(float(x + 1) - HALF_GRID, corner_heights[p11_idx], float(z + 1) - HALF_GRID)

			var uv00: Vector2 = Vector2(float(x) / GRID_SIZE, float(z) / GRID_SIZE)
			var uv10: Vector2 = Vector2(float(x + 1) / GRID_SIZE, float(z) / GRID_SIZE)
			var uv01: Vector2 = Vector2(float(x) / GRID_SIZE, float(z + 1) / GRID_SIZE)
			var uv11: Vector2 = Vector2(float(x + 1) / GRID_SIZE, float(z + 1) / GRID_SIZE)

			# Tri 1: v00, v10, v11
			_add_triangle(v00, v10, v11, uv00, uv10, uv11)
			# Tri 2: v00, v11, v01
			_add_triangle(v00, v11, v01, uv00, uv11, uv01)

	# Generate outer cliff skirts down to abyss
	_build_cliff_skirts(corner_heights, vert_count_axis)

	surface_tool.generate_normals()
	surface_tool.generate_tangents()
	var mesh: ArrayMesh = surface_tool.commit()

	if terrain_material:
		mesh.surface_set_material(0, terrain_material)

	return mesh

func _add_triangle(v1: Vector3, v2: Vector3, v3: Vector3, uv1: Vector2, uv2: Vector2, uv3: Vector2) -> void:
	surface_tool.set_uv(uv1)
	surface_tool.add_vertex(v1)
	surface_tool.set_uv(uv2)
	surface_tool.add_vertex(v2)
	surface_tool.set_uv(uv3)
	surface_tool.add_vertex(v3)

func _build_cliff_skirts(corner_heights: PackedFloat32Array, vert_axis: int) -> void:
	var skirt_y: float = -SKIRT_DEPTH

	# North Edge (z = 0)
	for x in range(GRID_SIZE):
		var top_left: Vector3 = Vector3(float(x) - HALF_GRID, corner_heights[x], -HALF_GRID)
		var top_right: Vector3 = Vector3(float(x + 1) - HALF_GRID, corner_heights[x + 1], -HALF_GRID)
		var bot_left: Vector3 = Vector3(float(x) - HALF_GRID, skirt_y, -HALF_GRID)
		var bot_right: Vector3 = Vector3(float(x + 1) - HALF_GRID, skirt_y, -HALF_GRID)
		_add_triangle(top_left, top_right, bot_right, Vector2.ZERO, Vector2.RIGHT, Vector2.ONE)
		_add_triangle(top_left, bot_right, bot_left, Vector2.ZERO, Vector2.ONE, Vector2.DOWN)

	# South Edge (z = GRID_SIZE)
	var sz_idx: int = GRID_SIZE * vert_axis
	for x in range(GRID_SIZE):
		var top_left: Vector3 = Vector3(float(x) - HALF_GRID, corner_heights[sz_idx + x], HALF_GRID)
		var top_right: Vector3 = Vector3(float(x + 1) - HALF_GRID, corner_heights[sz_idx + x + 1], HALF_GRID)
		var bot_left: Vector3 = Vector3(float(x) - HALF_GRID, skirt_y, HALF_GRID)
		var bot_right: Vector3 = Vector3(float(x + 1) - HALF_GRID, skirt_y, HALF_GRID)
		_add_triangle(top_right, top_left, bot_left, Vector2.RIGHT, Vector2.ZERO, Vector2.DOWN)
		_add_triangle(top_right, bot_left, bot_right, Vector2.RIGHT, Vector2.DOWN, Vector2.ONE)

	# West Edge (x = 0)
	for z in range(GRID_SIZE):
		var idx_top: int = z * vert_axis
		var idx_bot: int = (z + 1) * vert_axis
		var top_v: Vector3 = Vector3(-HALF_GRID, corner_heights[idx_top], float(z) - HALF_GRID)
		var bot_v: Vector3 = Vector3(-HALF_GRID, corner_heights[idx_bot], float(z + 1) - HALF_GRID)
		var skirt_top: Vector3 = Vector3(-HALF_GRID, skirt_y, float(z) - HALF_GRID)
		var skirt_bot: Vector3 = Vector3(-HALF_GRID, skirt_y, float(z + 1) - HALF_GRID)
		_add_triangle(top_v, bot_v, skirt_bot, Vector2.ZERO, Vector2.DOWN, Vector2.ONE)
		_add_triangle(top_v, skirt_bot, skirt_top, Vector2.ZERO, Vector2.ONE, Vector2.RIGHT)

	# East Edge (x = GRID_SIZE)
	for z in range(GRID_SIZE):
		var idx_top: int = z * vert_axis + GRID_SIZE
		var idx_bot: int = (z + 1) * vert_axis + GRID_SIZE
		var top_v: Vector3 = Vector3(HALF_GRID, corner_heights[idx_top], float(z) - HALF_GRID)
		var bot_v: Vector3 = Vector3(HALF_GRID, corner_heights[idx_bot], float(z + 1) - HALF_GRID)
		var skirt_top: Vector3 = Vector3(HALF_GRID, skirt_y, float(z) - HALF_GRID)
		var skirt_bot: Vector3 = Vector3(HALF_GRID, skirt_y, float(z + 1) - HALF_GRID)
		_add_triangle(bot_v, top_v, skirt_top, Vector2.DOWN, Vector2.ZERO, Vector2.RIGHT)
		_add_triangle(bot_v, skirt_top, skirt_bot, Vector2.DOWN, Vector2.RIGHT, Vector2.ONE)
