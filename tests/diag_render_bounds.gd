extends Node3D

## v0.9.2.3: which AABB does the RENDERER actually use?
##
## The first camera-intrusion sweep flagged every character mesh as a ~130 m
## box swallowing the camera. That number comes from VisualInstance3D.get_aabb(),
## and before treating it as the artifact it has to be established whether
## get_aabb() reports the corrected bounds (custom_aabb, set by
## AnimationController._fix_render_bounds) or the raw mesh bounds that
## correction exists to replace.
##
## If get_aabb() ignores custom_aabb then the giant numbers are the *input* to
## a fix that is already in place, the diagnostic was measuring the wrong
## thing, and the artifact is elsewhere. That is a measurement worth making
## before writing any more code.

const MainScene := preload("res://scenes/Main.tscn")


func _ready() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(60):
		await get_tree().process_frame

	var shown := 0
	for p in (main.home_players + main.away_players):
		var skel: Skeleton3D = _find_skeleton(p)
		if skel == null:
			continue
		for child in skel.get_children():
			var mi := child as MeshInstance3D
			if mi == null:
				continue
			var raw: AABB = mi.get_aabb()
			var custom: AABB = mi.custom_aabb
			var xf: Transform3D = mi.global_transform
			var raw_world: AABB = xf * raw
			var custom_world: AABB = xf * custom
			print("BOUNDS: %s" % mi.get_path())
			print("BOUNDS:   node scale        %.3f" % xf.basis.get_scale().x)
			print("BOUNDS:   get_aabb()  size  (%.2f, %.2f, %.2f)" % [raw.size.x, raw.size.y, raw.size.z])
			print("BOUNDS:   custom_aabb size  (%.2f, %.2f, %.2f)  empty=%s" % [
				custom.size.x, custom.size.y, custom.size.z,
				str(custom.size.length() < 0.0001)])
			print("BOUNDS:   raw    in world   (%.2f, %.2f, %.2f)" % [
				raw_world.size.x, raw_world.size.y, raw_world.size.z])
			print("BOUNDS:   custom in world   (%.2f, %.2f, %.2f)" % [
				custom_world.size.x, custom_world.size.y, custom_world.size.z])
			print("BOUNDS:   get_aabb() == custom_aabb ? %s" % str(raw == custom))
			shown += 1
			if shown >= 4:
				break
		if shown >= 4:
			break

	# What does the character actually MEASURE on screen? A 1.6 m player is
	# 1.6 m regardless of what any bounding box says, so this separates a
	# bounds bug from a geometry bug.
	print("BOUNDS: ---- real rendered extent, from vertex data ----")
	for p in (main.home_players + main.away_players).slice(0, 3):
		var skel: Skeleton3D = _find_skeleton(p)
		if skel == null:
			continue
		var lo := Vector3(INF, INF, INF)
		var hi := Vector3(-INF, -INF, -INF)
		for b in range(skel.get_bone_count()):
			var o: Vector3 = skel.global_transform * skel.get_bone_global_pose(b).origin
			lo = Vector3(minf(lo.x, o.x), minf(lo.y, o.y), minf(lo.z, o.z))
			hi = Vector3(maxf(hi.x, o.x), maxf(hi.y, o.y), maxf(hi.z, o.z))
		print("BOUNDS:   %s posed bone extent in WORLD (%.2f, %.2f, %.2f) at y %.2f..%.2f" % [
			p.name, hi.x - lo.x, hi.y - lo.y, hi.z - lo.z, lo.y, hi.y])

	get_tree().quit()


func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var r: Skeleton3D = _find_skeleton(c)
		if r != null:
			return r
	return null
