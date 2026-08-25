extends Node3D

## Reusable inspection tool for the character asset pipeline. Run this
## against any new .glb/.gltf BEFORE wiring it into CharacterRegistry, to
## get exactly the numbers the AnimationController auto-fit needs and to
## catch obvious problems (missing skeleton, huge polycount, etc.) early.
##
## Usage:
##   1. Drop the model file under assets/characters/<name>/<name>.glb
##   2. godot --headless --path . tools/InspectCharacterModel.tscn -- <res://path/to/model.glb>
##      (defaults to assets/characters/tokai_teio/tokai_teio.glb if no arg given)
##
## Prints: node/mesh/material/animation counts, vertex count, skeleton
## bone count, per-image texture dimensions, and the measured bind-pose
## height (the same measurement AnimationController uses to auto-scale
## the model to the game's calibrated ~1.6m character height).

const DEFAULT_PATH := "res://assets/characters/tokai_teio/tokai_teio.glb"


func _ready() -> void:
	var path := DEFAULT_PATH
	var user_args := OS.get_cmdline_user_args()
	if not user_args.is_empty():
		path = user_args[0]

	if not ResourceLoader.exists(path):
		printerr("No model found at: ", path)
		get_tree().quit(1)
		return

	print("Inspecting: ", path)
	var scene: PackedScene = load(path)
	var instance: Node3D = scene.instantiate()
	add_child(instance)
	await get_tree().process_frame
	# Note: headless runs of this tool print a harmless trailing
	# "ERROR: Parameter 'm' is null. at: mesh_get_surface_count" from the
	# dummy rendering driver during scene teardown after quit() -- it's an
	# engine-level artifact of tearing down a skinned mesh under
	# --headless (no GPU driver), appears after all diagnostic output
	# above, and does not affect the exit code or the numbers reported.

	print("\n=== SCENE TREE SUMMARY ===")
	var stats := {"nodes": 0, "meshes": 0, "materials": {}, "vertices": 0}
	_walk(instance, stats)
	print("Total nodes: ", stats["nodes"])
	print("MeshInstance3D count: ", stats["meshes"])
	print("Approx total vertices: ", stats["vertices"])

	var skeleton := _find_skeleton(instance)
	print("\n=== SKELETON ===")
	if skeleton:
		print("Bone count: ", skeleton.get_bone_count())
		if skeleton.get_bone_count() > 150:
			print("NOTE: high bone count -- likely fine for a single character but worth")
			print("      profiling on-device if many of this model are on screen at once.")
	else:
		print("No skeleton found (static mesh).")

	var anim_player := _find_animation_player(instance)
	print("\n=== ANIMATIONS ===")
	if anim_player and not anim_player.get_animation_list().is_empty():
		print("Clips found: ", anim_player.get_animation_list())
		print("These will be auto-matched to gameplay states/actions by keyword")
		print("(see AnimationController.STATE_KEYWORDS / ACTION_KEYWORDS).")
	else:
		print("No animation clips -- AnimationController will use its procedural")
		print("fallback (bob/lean/pulse) for this model automatically.")

	var height := _measure_height(instance)
	print("\n=== SCALE ===")
	print("Measured bind-pose height (model's own units): ", height)
	if height > 0.01:
		print("AnimationController will auto-scale this by roughly %.3fx to reach" % (1.6 / height))
		print("the game's calibrated 1.6m character height. No manual scale entry needed.")
	else:
		printerr("Height measured too small/degenerate -- inspect the model manually,")
		printerr("auto-fit will likely fail safe (leave scale untouched) for this file.")

	print("\n=== NEXT STEPS ===")
	print("1. Add an entry to scripts/data/CharacterRegistry.gd MODELS pointing at this file.")
	print("2. Set visual_id on the PlayerData entries that should use it.")
	print("3. Add a license/attribution block to assets/characters/CREDITS.md.")
	print("4. If the character visually faces the wrong way in-game, set")
	print("   AnimationController.facing_correction_degrees to 180 for that visual")
	print("   (or wire a per-visual override if multiple models need different corrections).")

	get_tree().quit(0)


func _walk(node: Node, stats: Dictionary) -> void:
	stats["nodes"] += 1
	if node is MeshInstance3D and node.mesh:
		stats["meshes"] += 1
		var mesh: Mesh = node.mesh
		for s in range(mesh.get_surface_count()):
			var arrays := mesh.surface_get_arrays(s)
			if arrays.size() > Mesh.ARRAY_VERTEX and arrays[Mesh.ARRAY_VERTEX] != null:
				stats["vertices"] += arrays[Mesh.ARRAY_VERTEX].size()
	for child in node.get_children():
		_walk(child, stats)


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found:
			return found
	return null


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found := _find_animation_player(child)
		if found:
			return found
	return null


func _measure_height(root: Node) -> float:
	var aabb := AABB()
	var first := true
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D and node.mesh:
			var local_aabb: AABB = node.mesh.get_aabb()
			var world_aabb: AABB = _transform_aabb(node.global_transform, local_aabb)
			if first:
				aabb = world_aabb
				first = false
			else:
				aabb = aabb.merge(world_aabb)
		for child in node.get_children():
			stack.append(child)
	return aabb.size.y


func _transform_aabb(xform: Transform3D, aabb: AABB) -> AABB:
	var corners := [
		aabb.position,
		aabb.position + Vector3(aabb.size.x, 0, 0),
		aabb.position + Vector3(0, aabb.size.y, 0),
		aabb.position + Vector3(0, 0, aabb.size.z),
		aabb.position + Vector3(aabb.size.x, aabb.size.y, 0),
		aabb.position + Vector3(aabb.size.x, 0, aabb.size.z),
		aabb.position + Vector3(0, aabb.size.y, aabb.size.z),
		aabb.position + aabb.size,
	]
	var result := AABB()
	var first := true
	for c in corners:
		var wc: Vector3 = xform * c
		if first:
			result = AABB(wc, Vector3.ZERO)
			first = false
		else:
			result = result.expand(wc)
	return result
