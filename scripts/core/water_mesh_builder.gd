class_name WaterMeshBuilder
extends RefCounted

## Dynamically generates the 3D liquid mesh from heightfield water layers.
## Rebuilds surface quads and drop-skirts only where water volume exists.

const GRID_SIZE: int = FluidSim.GRID_SIZE
const HALF_GRID: float = GRID_SIZE * 0.5
const MIN_WATER: float = 0.02

var surface_tool: SurfaceTool
var water_material: ShaderMaterial

func _init(material: ShaderMaterial = null) -> void:
	surface_tool = SurfaceTool.new()
	water_material = material

func build_mesh(sim: FluidSim) -> ArrayMesh:
	surface_tool.clear()
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)

	var vert_axis: int = GRID_SIZE + 1

	# Pre-sample whether cells have active water
	var is_wet: PackedByteArray = PackedByteArray()
	is_wet.resize(sim.CELL_COUNT)
	var has_any_water: bool = false

	for i in range(sim.CELL_COUNT):
		var wet: bool = sim.water[i] > MIN_WATER
		is_wet[i] = 1 if wet else 0
		if wet:
			has_any_water = true

	if not has_any_water:
		# Return empty mesh if completely dry
		var empty_mesh: ArrayMesh = surface_tool.commit()
		return empty_mesh

	# Precompute smoothed corner water surface heights
	var corner_heights: PackedFloat32Array = PackedFloat32Array()
	corner_heights.resize(vert_axis * vert_axis)

	for cz in range(vert_axis):
		for cx in range(vert_axis):
			var sum: float = 0.0
			var count: int = 0
			for dy in range(-1, 1):
				for dx in range(-1, 1):
					var sx: int = cx + dx
					var sy: int = cz + dy
					if sim.is_in_bounds(sx, sy):
						var idx: int = sim.get_index(sx, sy)
						if is_wet[idx] == 1:
							sum += sim.terrain[idx] + sim.water[idx]
							count += 1
			var c_idx: int = cz * vert_axis + cx
			corner_heights[c_idx] = sum / float(max(count, 1)) if count > 0 else 0.0

	# Generate surface quads for wet cells
	for z in range(GRID_SIZE):
		for x in range(GRID_SIZE):
			var cell_idx: int = sim.get_index(x, z)
			if is_wet[cell_idx] == 0:
				continue

			var p00_idx: int = z * vert_axis + x
			var p10_idx: int = z * vert_axis + (x + 1)
			var p01_idx: int = (z + 1) * vert_axis + x
			var p11_idx: int = (z + 1) * vert_axis + (x + 1)

			var v00: Vector3 = Vector3(float(x) - HALF_GRID, corner_heights[p00_idx], float(z) - HALF_GRID)
			var v10: Vector3 = Vector3(float(x + 1) - HALF_GRID, corner_heights[p10_idx], float(z) - HALF_GRID)
			var v01: Vector3 = Vector3(float(x) - HALF_GRID, corner_heights[p01_idx], float(z + 1) - HALF_GRID)
			var v11: Vector3 = Vector3(float(x + 1) - HALF_GRID, corner_heights[p11_idx], float(z + 1) - HALF_GRID)

			var uv00: Vector2 = Vector2(float(x) / GRID_SIZE, float(z) / GRID_SIZE)
			var uv10: Vector2 = Vector2(float(x + 1) / GRID_SIZE, float(z) / GRID_SIZE)
			var uv01: Vector2 = Vector2(float(x) / GRID_SIZE, float(z + 1) / GRID_SIZE)
			var uv11: Vector2 = Vector2(float(x + 1) / GRID_SIZE, float(z + 1) / GRID_SIZE)

			_add_triangle(v00, v10, v11, uv00, uv10, uv11)
			_add_triangle(v00, v11, v01, uv00, uv11, uv01)

			# Perimeter water drop-skirts where water flows off the island edge
			var t_h: float = sim.terrain[cell_idx]
			if z == 0: # North drop
				_add_triangle(v00, v10, Vector3(v10.x, -2.0, v10.z), uv00, uv10, uv10)
				_add_triangle(v00, Vector3(v10.x, -2.0, v10.z), Vector3(v00.x, -2.0, v00.z), uv00, uv10, uv00)
			if z == GRID_SIZE - 1: # South drop
				_add_triangle(v11, v01, Vector3(v01.x, -2.0, v01.z), uv11, uv01, uv01)
				_add_triangle(v11, Vector3(v01.x, -2.0, v01.z), Vector3(v11.x, -2.0, v11.z), uv11, uv01, uv11)
			if x == 0: # West drop
				_add_triangle(v01, v00, Vector3(v00.x, -2.0, v00.z), uv01, uv00, uv00)
				_add_triangle(v01, Vector3(v00.x, -2.0, v00.z), Vector3(v01.x, -2.0, v01.z), uv01, uv00, uv01)
			if x == GRID_SIZE - 1: # East drop
				_add_triangle(v10, v11, Vector3(v11.x, -2.0, v11.z), uv10, uv11, uv11)
				_add_triangle(v10, Vector3(v11.x, -2.0, v11.z), Vector3(v10.x, -2.0, v10.z), uv10, uv11, uv10)

	surface_tool.generate_normals()
	surface_tool.generate_tangents()
	var mesh: ArrayMesh = surface_tool.commit()

	if water_material:
		mesh.surface_set_material(0, water_material)

	return mesh

func _add_triangle(v1: Vector3, v2: Vector3, v3: Vector3, uv1: Vector2, uv2: Vector2, uv3: Vector2) -> void:
	surface_tool.set_uv(uv1)
	surface_tool.add_vertex(v1)
	surface_tool.set_uv(uv2)
	surface_tool.add_vertex(v2)
	surface_tool.set_uv(uv3)
	surface_tool.add_vertex(v3)
