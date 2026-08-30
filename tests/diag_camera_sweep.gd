extends Node3D

## v0.9.2.3 sections 1-3: drive the camera through EVERY pose the game can
## produce and record what the frame contains at each one.
##
## A 60-second match is a sample, not a proof. The first live sweep flagged
## nothing, but its camera only ever reached x 1.85..17.81 -- the goals are at
## x +-29, so the run never visited the poses QA is describing. "No occurrences
## in one match" from a camera that never went there is not evidence.
##
## The camera rig follows lerp(controlled player, ball, 0.28) with no clamp of
## any kind (CameraController._process), so its reachable set is the whole area
## the ball can reach, goal mouths and corners included. This walks that set
## directly, with the real camera node, the real offsets and the real FOV, and
## at each pose measures:
##
##   INSIDE    the camera origin is inside an object's world bounds
##   NEAR      an object's bounds come within NEAR_MARGIN of the camera origin
##   coverage  what fraction of the rendered frame each object really occupies,
##             by casting a grid of camera rays and intersecting them with the
##             object's bounds
##
## Coverage is reported as a maximum per object rather than as a pass/fail,
## because the question is not "did a threshold trip" but "what is the largest
## thing that has ever filled this screen, and where was the camera when it
## did".

const MainScene := preload("res://scenes/Main.tscn")

## The reachable focus set. The playable area is x +-35, z +-23 (Field.tscn's
## walls); the ball can sit in the back of a net at x +-32.2.
const X_MIN := -33.0
const X_MAX := 33.0
const Z_MIN := -21.0
const Z_MAX := 21.0
const X_STEPS := 34
const Z_STEPS := 15

const NEAR_MARGIN := 0.35
const RAY_COLS := 32
const RAY_ROWS := 18

## Report every object that has ever covered at least this much of the frame.
const REPORT_COVERAGE := 0.10
## Capture a frame whenever an object first exceeds this.
const SHOT_COVERAGE := 0.25
const SHOT_LIMIT := 30
const SHOT_DIR := "user://sweep"

var _main: Node3D
var _rig: Node3D
var _camera: Camera3D
var _drawables: Array = []
var _shots := 0

## node path -> {max coverage, camera position at that maximum, name}
var _peak := {}
var _inside := {}
var _near := {}
var _shot_for := {}


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	_main = MainScene.instantiate()
	add_child(_main)
	for i in range(90):
		await get_tree().process_frame

	_camera = get_viewport().get_camera_3d()
	_rig = _camera.get_parent()
	# Take the rig off its follow logic so the sweep, not the match, decides
	# where the camera goes. The camera's own local offset, rotation and FOV
	# are left exactly as the game sets them.
	var controller: Node = _rig
	if controller.has_method("set_target"):
		controller.set_target(null)
		controller.set_ball(null)
	controller.set_process(false)

	print("SWEEP: camera local offset (%.2f, %.2f, %.2f) fov %.1f near %.3f" % [
		_camera.position.x, _camera.position.y, _camera.position.z,
		_camera.fov, _camera.near])
	_collect(_main)
	print("SWEEP: %d drawables, %d poses" % [_drawables.size(), X_STEPS * Z_STEPS])

	for xi in range(X_STEPS):
		var x: float = lerpf(X_MIN, X_MAX, float(xi) / float(X_STEPS - 1))
		for zi in range(Z_STEPS):
			var z: float = lerpf(Z_MIN, Z_MAX, float(zi) / float(Z_STEPS - 1))
			_rig.global_position = Vector3(x, 0.0, z)
			# Two frames: one to apply the transform, one to render it.
			await get_tree().process_frame
			await get_tree().process_frame
			_measure()

	_report()
	get_tree().quit()


func _collect(n: Node) -> void:
	if n is VisualInstance3D and not (n is Camera3D):
		_drawables.append(n)
	for c in n.get_children():
		_collect(c)


func _effective_aabb(d: VisualInstance3D) -> AABB:
	var gi := d as GeometryInstance3D
	if gi != null and gi.custom_aabb.size.length() > 0.0001:
		return gi.custom_aabb
	return d.get_aabb()


func _measure() -> void:
	var cam: Vector3 = _camera.global_position
	for d in _drawables:
		if not is_instance_valid(d) or not d.is_visible_in_tree():
			continue
		var world: AABB = d.global_transform * _effective_aabb(d)
		var key: String = str(d.get_path())

		if world.has_point(cam):
			if not _inside.has(key):
				_inside[key] = cam
				print("SWEEP: [INSIDE] camera (%.2f, %.2f, %.2f) is INSIDE %s" % [
					cam.x, cam.y, cam.z, d.get_path()])
				_shoot("INSIDE", d, cam)
		elif _aabb_distance(world, cam) < NEAR_MARGIN:
			if not _near.has(key):
				_near[key] = cam
				print("SWEEP: [NEAR] camera (%.2f, %.2f, %.2f) is %.3f m from %s" % [
					cam.x, cam.y, cam.z, _aabb_distance(world, cam), d.get_path()])
				_shoot("NEAR", d, cam)

		# Cheap pre-filter, then real measured coverage.
		var radius: float = world.size.length() * 0.5
		var dist: float = cam.distance_to(world.get_center())
		if radius / maxf(dist, 0.001) < 0.20:
			continue
		var cover: float = _coverage(world)
		var best: float = float(_peak.get(key, {}).get("cover", 0.0))
		if cover > best:
			_peak[key] = {"cover": cover, "cam": cam, "name": d.name,
				"size": world.size, "dist": dist}
		if cover >= SHOT_COVERAGE and not _shot_for.has(key):
			_shot_for[key] = true
			_shoot("COVER%02d" % int(cover * 100.0), d, cam)


func _coverage(box: AABB) -> float:
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var hits := 0
	var total := 0
	for cx in range(RAY_COLS):
		for cy in range(RAY_ROWS):
			var sp := Vector2(
				vp.x * (float(cx) + 0.5) / float(RAY_COLS),
				vp.y * (float(cy) + 0.5) / float(RAY_ROWS))
			total += 1
			if box.intersects_ray(_camera.project_ray_origin(sp),
					_camera.project_ray_normal(sp)) != null:
				hits += 1
	return float(hits) / float(maxi(total, 1))


func _aabb_distance(box: AABB, p: Vector3) -> float:
	var lo: Vector3 = box.position
	var hi: Vector3 = box.position + box.size
	return Vector3(
		maxf(maxf(lo.x - p.x, 0.0), p.x - hi.x),
		maxf(maxf(lo.y - p.y, 0.0), p.y - hi.y),
		maxf(maxf(lo.z - p.z, 0.0), p.z - hi.z)).length()


func _shoot(tag: String, node: Node3D, cam: Vector3) -> void:
	if _shots >= SHOT_LIMIT:
		return
	_shots += 1
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png("%s/%s_%s_cam%+06.1f%+06.1f.png" % [
		SHOT_DIR, tag, node.name, cam.x, cam.z])


func _report() -> void:
	print("SWEEP: ================ RESULT ================")
	print("SWEEP: objects the camera was ever INSIDE: %d" % _inside.size())
	for k in _inside:
		print("SWEEP:   %s at camera (%.2f, %.2f, %.2f)" % [
			k, _inside[k].x, _inside[k].y, _inside[k].z])
	print("SWEEP: objects that ever came within %.2f m of the camera: %d" % [
		NEAR_MARGIN, _near.size()])
	for k in _near:
		print("SWEEP:   %s at camera (%.2f, %.2f, %.2f)" % [
			k, _near[k].x, _near[k].y, _near[k].z])

	print("SWEEP: ---- largest measured screen coverage, per object ----")
	var keys: Array = _peak.keys()
	keys.sort_custom(func(a, b): return _peak[a]["cover"] > _peak[b]["cover"])
	for k in keys:
		var e: Dictionary = _peak[k]
		if e["cover"] < REPORT_COVERAGE:
			continue
		print("SWEEP:   %5.1f%% of frame  %-22s  size (%.1f, %.1f, %.1f) at %.1f m, camera (%.1f, %.1f)" % [
			e["cover"] * 100.0, e["name"],
			e["size"].x, e["size"].y, e["size"].z, e["dist"],
			e["cam"].x, e["cam"].z])
	print("SWEEP: screenshots written: %d" % _shots)
