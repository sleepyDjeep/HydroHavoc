class_name MascotMeshMerge
extends RefCounted

## The streamer mascot GLB ships five skinned mesh instances carrying five surfaces and five
## separate StandardMaterial3D resources, so every mascot would cost five draws per render pass
## (twenty with the three shadow cascades) even though all five surfaces are the same material:
## same 1024px albedo, same roughness 1.0, same metallic 0.
##
## This rebuilds the model's geometry into one ArrayMesh with one surface per distinct shading
## setup - one on this model. The merged mesh goes on the first mesh instance - which keeps
## that instance's skin and skeleton binding untouched - and the other four are hidden. Nothing
## else about the model changes, so the render is pixel-identical: the only triangles removed
## are duplicate materials, not geometry.
##
## One mesh is built per model and shared by every mascot instance. The build reads the
## imported meshes and their local transforms, so it can run before the node is in the tree.
## The result is a plain ArrayMesh: it does not inherit the import's generated LODs.

## Geometry that ended up merged, keyed by model path. Static so 32 mascots share one build.
static var _cache: Dictionary = {}

## Merges the model behind `visual_root` in place and hides every mesh but the merged one.
## Returns false, leaving the model untouched, when there is nothing to merge or the geometry
## cannot be combined safely.
static func apply(visual_root: Node3D, model_key: String) -> bool:
	var meshes: Array = []
	_collect_meshes(visual_root, meshes)
	if meshes.size() < 2:
		return false
	var host: MeshInstance3D = meshes[0]
	if not _cache.has(model_key):
		_cache[model_key] = _build(host, meshes, visual_root)
	var merged: ArrayMesh = _cache[model_key]
	if merged == null:
		return false
	host.mesh = merged
	host.transform = Transform3D.IDENTITY
	for i in range(1, meshes.size()):
		meshes[i].visible = false
	return true

## Distinct shading setups, albedo included: two materials that differ only in colour must not
## share a surface, because the merged surface keeps one material resource.
static func _signature(mat: StandardMaterial3D) -> String:
	if mat == null:
		return "none"
	var texture: String = mat.albedo_texture.resource_path if mat.albedo_texture else "-"
	return "r%.4f m%.4f s%.4f sm%d cull%d shade%d transp%d depth%d vcol%d uv%s %s tex%s" % [
		mat.roughness, mat.metallic, mat.metallic_specular, mat.specular_mode, mat.cull_mode,
		mat.shading_mode, mat.transparency, mat.depth_draw_mode,
		int(mat.vertex_color_use_as_albedo), str(mat.uv1_scale), str(mat.albedo_color), texture]

static func _build(host: MeshInstance3D, meshes: Array, root: Node3D) -> ArrayMesh:
	var groups: Dictionary = {}
	var order: Array = []
	# The meshes are siblings (children of the skeleton), not descendants of the host, so both
	# sides are taken relative to the model root and combined rather than walked directly.
	var to_root: Transform3D = _transform_to_root(host, root).affine_inverse()
	for mi in meshes:
		var mesh: ArrayMesh = mi.mesh
		if mesh == null:
			continue
		var to_host: Transform3D = to_root * _transform_to_root(mi, root)
		for s in range(mesh.get_surface_count()):
			var mat: StandardMaterial3D = mesh.surface_get_material(s) as StandardMaterial3D
			var key: String = _signature(mat)
			if not groups.has(key):
				groups[key] = {"mat": mat, "acc": _empty_acc()}
				order.append(key)
			_append(groups[key]["acc"], mesh, s, to_host)

	var out: ArrayMesh = ArrayMesh.new()
	for key in order:
		var acc: Dictionary = groups[key]["acc"]
		if acc["mismatch"]:
			return null
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays(acc))
		out.surface_set_material(out.get_surface_count() - 1, groups[key]["mat"])
	return out

## Transform of `node` relative to `root`, from local transforms only, so it works before the
## model has entered the tree.
static func _transform_to_root(node: Node3D, root: Node3D) -> Transform3D:
	var xf: Transform3D = node.transform
	var parent: Node = node.get_parent()
	while parent != null and parent != root:
		if parent is Node3D:
			xf = (parent as Node3D).transform * xf
		parent = parent.get_parent()
	return xf

static func _empty_acc() -> Dictionary:
	return {"verts": PackedVector3Array(), "normals": PackedVector3Array(),
		"tangents": PackedFloat32Array(), "uvs": PackedVector2Array(),
		"bones": PackedInt32Array(), "weights": PackedFloat32Array(),
		"indices": PackedInt32Array(), "has_bones": false, "mismatch": false}

## Appends one source surface, transformed into the host's space. Every surface of this model
## is skinned, so a run that mixes skinned and static surfaces is refused rather than
## collapsed onto the skeleton origin.
static func _append(acc: Dictionary, mesh: ArrayMesh, s: int, xform: Transform3D) -> void:
	var arrays: Array = mesh.surface_get_arrays(s)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
	var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT] if arrays[Mesh.ARRAY_TANGENT] != null else PackedFloat32Array()
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES] if arrays[Mesh.ARRAY_BONES] != null else PackedInt32Array()
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS] if arrays[Mesh.ARRAY_WEIGHTS] != null else PackedFloat32Array()
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()

	var base: int = acc["verts"].size()
	if (not bones.is_empty()) != acc["has_bones"] and base > 0:
		acc["mismatch"] = true
		return
	var basis: Basis = xform.basis
	for i in range(verts.size()):
		acc["verts"].append(xform * verts[i])
		if not normals.is_empty():
			acc["normals"].append((basis * normals[i]).normalized())
		if not tangents.is_empty():
			var t: Vector3 = basis * Vector3(tangents[i * 4], tangents[i * 4 + 1], tangents[i * 4 + 2])
			acc["tangents"].append_array(PackedFloat32Array([t.x, t.y, t.z, tangents[i * 4 + 3]]))
		if not uvs.is_empty():
			acc["uvs"].append(uvs[i])
	if not bones.is_empty():
		acc["bones"].append_array(bones)
		acc["weights"].append_array(weights)
		acc["has_bones"] = true
	if indices.is_empty():
		for i in range(verts.size()):
			acc["indices"].append(base + i)
	else:
		for i in indices:
			acc["indices"].append(base + i)

static func _arrays(acc: Dictionary) -> Array:
	var out: Array = []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = acc["verts"]
	if not acc["normals"].is_empty():
		out[Mesh.ARRAY_NORMAL] = acc["normals"]
	if not acc["tangents"].is_empty():
		out[Mesh.ARRAY_TANGENT] = acc["tangents"]
	if not acc["uvs"].is_empty():
		out[Mesh.ARRAY_TEX_UV] = acc["uvs"]
	if acc["has_bones"]:
		out[Mesh.ARRAY_BONES] = acc["bones"]
		out[Mesh.ARRAY_WEIGHTS] = acc["weights"]
	out[Mesh.ARRAY_INDEX] = acc["indices"]
	return out

static func _collect_meshes(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child is MeshInstance3D and child.mesh:
			out.append(child)
		_collect_meshes(child, out)
