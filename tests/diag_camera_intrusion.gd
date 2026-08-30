extends Node3D

## v0.9.2.3 section 1-3: OBJECT IDENTITY for the remaining visual artifact.
##
## v0.9.2.2 concluded the artifact was the stands rendering unlit, and fixing
## the ambient flag measurably reduced it. Human QA says it is reduced but NOT
## gone, so that explanation was incomplete. The brief is explicit: do not
## assume the same cause, and do not use "dark fraction" -- name the object.
##
## So this watches a live match from the real gameplay camera and, every
## rendered frame, tests every drawable in the scene against the camera:
##
##   INSIDE   the camera origin is inside the object's world AABB
##            -- the camera is physically inside that mesh
##   NEAR     the object's world AABB comes within NEAR_MARGIN of the camera
##            origin, i.e. it is crossing/behind the 0.05 m near plane
##   HUGE     the object actually covers more than HUGE_COVERAGE of the
##            rendered frame, measured by casting a grid of rays through the
##            viewport and intersecting them with the object's world AABB
##            (this is real screen coverage, not a luminance statistic)
##   JUMP     the AABB centre moved more than JUMP_DISTANCE in one frame, or
##            its size changed by more than JUMP_SCALE x
##   NAN      any non-finite value in the transform or the AABB
##
## Every flag prints the node path, the owning group, the world transform, the
## world AABB, the camera distance, and -- for a character -- the animation
## that was playing and the skeleton's own bounds, which is section 4's
## "prove animation is or is not correlated".

const MainScene := preload("res://scenes/Main.tscn")

const SECONDS := 60
const WARMUP_FRAMES := 90

## Camera-intrusion thresholds. The camera's near plane is 0.05 m; anything
## whose surface comes within 0.35 m of the camera origin is either clipping
## through it or about to.
const NEAR_MARGIN := 0.35

## Real screen coverage, measured by ray grid. A stand slab filling the frame
## is what QA is describing; the pitch itself legitimately fills the lower
## half, so the ground is exempt from HUGE.
const HUGE_COVERAGE := 0.55
const RAY_COLS := 32
const RAY_ROWS := 18

const JUMP_DISTANCE := 6.0
const JUMP_SCALE := 2.5

## Cheap pre-filter before the ray grid: angular radius of the bounding
## sphere. Only candidates that could plausibly fill the screen get measured.
const CANDIDATE_ANGULAR := 0.8

const SHOT_LIMIT := 40
const SHOT_DIR := "user://intrusion"

## Capture the real gameplay camera on a fixed cadence as well as on flags.
## Human QA watches the match; a diagnostic that only screenshots its own
## triggers can only ever confirm what it already believes.
const SHOT_EVERY := 36

var _main: Node3D
var _camera: Camera3D
var _drawables: Array = []
var _prev: Dictionary = {}
var _flags: Array = []
var _shots := 0
var _frame := 0

## Camera path, so section 3 can be answered directly: where did the camera
## actually go, and did that put it inside stadium geometry?
var _cam_min := Vector3(INF, INF, INF)
var _cam_max := Vector3(-INF, -INF, -INF)
var _cam_track: Array = []

## Per-object flag tallies, so the report names the offender rather than
## reporting an aggregate.
var _by_node := {}


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	_main = MainScene.instantiate()
	add_child(_main)
	for i in range(WARMUP_FRAMES):
		await get_tree().process_frame
	_camera = get_viewport().get_camera_3d()
	if _camera == null:
		print("INTRUSION: FATAL no active camera")
		get_tree().quit()
		return
	print("INTRUSION: camera %s near=%.3f far=%.1f fov=%.1f keep=%d" % [
		_camera.get_path(), _camera.near, _camera.far, _camera.fov, _camera.keep_aspect])
	var vp: Vector2 = get_viewport().get_visible_rect().size
	print("INTRUSION: viewport %dx%d" % [int(vp.x), int(vp.y)])
	_refresh_drawables()
	print("INTRUSION: watching %d drawables for %ds" % [_drawables.size(), SECONDS])

	for i in range(SECONDS * 60):
		await get_tree().process_frame
		_frame += 1
		if _frame % 45 == 0:
			_refresh_drawables()
		_scan()
		if _frame % SHOT_EVERY == 0:
			_timed_shot()

	_report()
	get_tree().quit()


func _refresh_drawables() -> void:
	_drawables.clear()
	_collect(_main)


func _collect(n: Node) -> void:
	if n is VisualInstance3D and not (n is Camera3D):
		_drawables.append(n)
	for c in n.get_children():
		_collect(c)


## Which subsystem owns this node? The brief asks for character / stadium /
## object, not just a path.
func _group_of(n: Node3D) -> String:
	var p: String = str(n.get_path())
	if p.find("/Players/") >= 0:
		return "CHARACTER"
	if p.find("/Ball") >= 0:
		return "BALL"
	if p.find("Stand") >= 0:
		return "STAND"
	if p.find("Goal") >= 0:
		return "GOAL"
	if p.find("Wall") >= 0 or p.find("Curb") >= 0:
		return "WALL"
	if p.find("Ground") >= 0:
		return "GROUND"
	if p.find("Bench") >= 0 or p.find("Flag") >= 0:
		return "PROP"
	return "OTHER"


func _scan() -> void:
	var cam_pos: Vector3 = _camera.global_position
	_cam_min = Vector3(minf(_cam_min.x, cam_pos.x), minf(_cam_min.y, cam_pos.y), minf(_cam_min.z, cam_pos.z))
	_cam_max = Vector3(maxf(_cam_max.x, cam_pos.x), maxf(_cam_max.y, cam_pos.y), maxf(_cam_max.z, cam_pos.z))
	if _frame % 10 == 0:
		_cam_track.append(cam_pos)

	for d in _drawables:
		if not is_instance_valid(d) or not d.is_visible_in_tree():
			continue
		var xf: Transform3D = d.global_transform
		var local: AABB = _effective_aabb(d)
		var key: String = str(d.get_path())

		if not _finite_xf(xf) or not _finite_aabb(local):
			_flag("NAN", d, cam_pos, xf, AABB(), 0.0, 0.0)
			continue

		var world: AABB = xf * local
		var centre: Vector3 = world.get_center()
		var radius: float = world.size.length() * 0.5
		var dist: float = cam_pos.distance_to(centre)
		var group: String = _group_of(d)

		# JUMP -- implausible movement or scaling between consecutive frames.
		if _prev.has(key):
			var pv: Dictionary = _prev[key]
			var moved: float = centre.distance_to(pv["c"])
			var grew: float = world.size.length() / maxf(pv["s"], 0.0001)
			if moved > JUMP_DISTANCE:
				_flag("JUMP", d, cam_pos, xf, world, dist, moved)
			elif grew > JUMP_SCALE or grew < 1.0 / JUMP_SCALE:
				_flag("SCALE", d, cam_pos, xf, world, dist, grew)
		_prev[key] = {"c": centre, "s": world.size.length()}

		# INSIDE / NEAR -- the camera-intersection test section 3 asks for.
		# The ground is a plane the camera is legitimately above; it can never
		# contain the camera, so it costs nothing to test everything.
		var surface: float = _aabb_distance(world, cam_pos)
		if world.has_point(cam_pos):
			_flag("INSIDE", d, cam_pos, xf, world, dist, 0.0)
			continue
		if surface < NEAR_MARGIN:
			_flag("NEAR", d, cam_pos, xf, world, dist, surface)
			continue

		# HUGE -- real measured screen coverage, for candidates only.
		if group == "GROUND":
			continue
		if radius / maxf(dist, 0.001) < CANDIDATE_ANGULAR:
			continue
		var cover: float = _coverage(world)
		if cover > HUGE_COVERAGE:
			_flag("HUGE", d, cam_pos, xf, world, dist, cover)


## Fraction of the rendered frame this world AABB actually occupies, by
## casting a grid of camera rays and intersecting each with the box. This is
## the honest answer to "how big is it on screen" and it does not care how
## bright or dark the object is.
func _coverage(box: AABB) -> float:
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var hits := 0
	var total := 0
	for cx in range(RAY_COLS):
		for cy in range(RAY_ROWS):
			var sp := Vector2(
				vp.x * (float(cx) + 0.5) / float(RAY_COLS),
				vp.y * (float(cy) + 0.5) / float(RAY_ROWS))
			var origin: Vector3 = _camera.project_ray_origin(sp)
			var dir: Vector3 = _camera.project_ray_normal(sp)
			total += 1
			if box.intersects_ray(origin, dir) != null or box.has_point(origin):
				hits += 1
	return float(hits) / float(maxi(total, 1))


## The bounds the RENDERER actually uses.
##
## MEASURED (tests/diag_render_bounds.gd): VisualInstance3D.get_aabb() returns
## the raw mesh AABB and ignores custom_aabb entirely. On these rigs that raw
## value is ~125 x 138 x 43 m -- the un-corrected bounds that
## AnimationController._fix_render_bounds exists to replace, not anything the
## renderer ever sees. The first version of this sweep read get_aabb() and duly
## flagged all 22 characters as giant boxes swallowing the camera, which was my
## measurement error rather than a defect: the corrected bounds are 2.16 x 2.51
## x 1.30 m in world space around a 1.55 m character.
##
## So the effective bounds are custom_aabb when one has been set, and the mesh
## bounds only when it has not.
func _effective_aabb(d: VisualInstance3D) -> AABB:
	var gi := d as GeometryInstance3D
	if gi != null and gi.custom_aabb.size.length() > 0.0001:
		return gi.custom_aabb
	return d.get_aabb()


## Distance from a point to the surface of an AABB (0 if inside).
func _aabb_distance(box: AABB, p: Vector3) -> float:
	var lo: Vector3 = box.position
	var hi: Vector3 = box.position + box.size
	var d := Vector3(
		maxf(maxf(lo.x - p.x, 0.0), p.x - hi.x),
		maxf(maxf(lo.y - p.y, 0.0), p.y - hi.y),
		maxf(maxf(lo.z - p.z, 0.0), p.z - hi.z))
	return d.length()


func _finite_xf(t: Transform3D) -> bool:
	for v in [t.origin, t.basis.x, t.basis.y, t.basis.z]:
		if not (is_finite(v.x) and is_finite(v.y) and is_finite(v.z)):
			return false
	return true


func _finite_aabb(a: AABB) -> bool:
	return is_finite(a.position.x) and is_finite(a.position.y) and is_finite(a.position.z) \
		and is_finite(a.size.x) and is_finite(a.size.y) and is_finite(a.size.z)


func _flag(kind: String, node: Node3D, cam: Vector3, xf: Transform3D, world: AABB,
		dist: float, value: float) -> void:
	var key: String = "%s|%s" % [kind, str(node.get_path())]
	_by_node[key] = _by_node.get(key, 0) + 1
	_flags.append({"kind": kind, "node": str(node.get_path()), "frame": _frame})

	# Print the first few of each kind per node in full; after that just count,
	# so a persistent condition does not drown the log.
	if _by_node[key] > 4:
		return

	var extra := ""
	if _group_of(node) == "CHARACTER":
		extra = _character_state(node)
	print("INTRUSION: [%s] f%d %s" % [kind, _frame, node.get_path()])
	print("INTRUSION:    group=%s class=%s vis=%s" % [
		_group_of(node), node.get_class(), str(node.is_visible_in_tree())])
	print("INTRUSION:    camera=(%.2f, %.2f, %.2f)  dist=%.2f  value=%.3f" % [
		cam.x, cam.y, cam.z, dist, value])
	print("INTRUSION:    xform origin=(%.2f, %.2f, %.2f) scale=(%.3f, %.3f, %.3f)" % [
		xf.origin.x, xf.origin.y, xf.origin.z,
		xf.basis.get_scale().x, xf.basis.get_scale().y, xf.basis.get_scale().z])
	print("INTRUSION:    world aabb pos=(%.2f, %.2f, %.2f) size=(%.2f, %.2f, %.2f)" % [
		world.position.x, world.position.y, world.position.z,
		world.size.x, world.size.y, world.size.z])
	if extra != "":
		print("INTRUSION:    %s" % extra)
	_shoot(kind, node)


## Section 4: at an artifact frame, what was the character doing? If the
## answer is never "a particular clip", animation is exonerated by measurement
## rather than by argument.
func _character_state(node: Node3D) -> String:
	var p: Node = node
	while p != null and not p.has_method("is_goalkeeper_role") and not ("animation_controller" in p):
		p = p.get_parent()
	if p == null:
		return ""
	var ac = p.get("animation_controller")
	if ac == null:
		return "character (no animation controller)"
	var skel_bounds := "n/a"
	var skel: Skeleton3D = null
	for c in _all_children(p):
		if c is Skeleton3D:
			skel = c
			break
	if skel != null:
		var lo := Vector3(INF, INF, INF)
		var hi := Vector3(-INF, -INF, -INF)
		for b in range(skel.get_bone_count()):
			var o: Vector3 = skel.get_bone_global_pose(b).origin
			if not (is_finite(o.x) and is_finite(o.y) and is_finite(o.z)):
				return "player=%s action=%s SKELETON HAS NON-FINITE BONE %d" % [
					p.name, str(ac.get("last_action")), b]
			lo = Vector3(minf(lo.x, o.x), minf(lo.y, o.y), minf(lo.z, o.z))
			hi = Vector3(maxf(hi.x, o.x), maxf(hi.y, o.y), maxf(hi.z, o.z))
		skel_bounds = "bones span (%.2f, %.2f, %.2f)" % [hi.x - lo.x, hi.y - lo.y, hi.z - lo.z]
	return "player=%s action=%s %s" % [p.name, str(ac.get("last_action")), skel_bounds]


func _all_children(n: Node) -> Array:
	var out: Array = []
	for c in n.get_children():
		out.append(c)
		out.append_array(_all_children(c))
	return out


## An unconditional sample of what the player is actually looking at, with the
## camera position in the filename so a bad frame can be traced back to a
## position on the pitch.
func _timed_shot() -> void:
	var c: Vector3 = _camera.global_position
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png("%s/t%04d_cam_%+06.1f_%+06.1f.png" % [SHOT_DIR, _frame, c.x, c.z])


func _shoot(kind: String, node: Node3D) -> void:
	if _shots >= SHOT_LIMIT:
		return
	_shots += 1
	var img: Image = get_viewport().get_texture().get_image()
	var safe: String = str(node.get_path()).replace("/", "_")
	img.save_png("%s/f%04d_%s%s.png" % [SHOT_DIR, _frame, kind, safe])


func _report() -> void:
	print("INTRUSION: ================ RESULT ================")
	print("INTRUSION: frames scanned: %d" % _frame)
	print("INTRUSION: camera travelled x %.2f..%.2f  y %.2f..%.2f  z %.2f..%.2f" % [
		_cam_min.x, _cam_max.x, _cam_min.y, _cam_max.y, _cam_min.z, _cam_max.z])

	var kinds := {}
	for f in _flags:
		kinds[f["kind"]] = kinds.get(f["kind"], 0) + 1
	if kinds.is_empty():
		print("INTRUSION: ZERO camera-intrusion / oversize / discontinuity events")
	for k in kinds:
		print("INTRUSION: %-7s %d events" % [k, kinds[k]])

	print("INTRUSION: ---- by object ----")
	var keys: Array = _by_node.keys()
	keys.sort_custom(func(a, b): return _by_node[a] > _by_node[b])
	for k in keys:
		print("INTRUSION:   %-6d %s" % [_by_node[k], k])

	# Section 3 answered directly: measure the camera against the stadium
	# shells it could plausibly have entered.
	print("INTRUSION: ---- camera vs stadium geometry ----")
	for d in _drawables:
		if not is_instance_valid(d):
			continue
		var g: String = _group_of(d)
		if g != "STAND" and g != "WALL" and g != "GOAL":
			continue
		var world: AABB = d.global_transform * d.get_aabb()
		var closest := INF
		for c in _cam_track:
			closest = minf(closest, _aabb_distance(world, c))
		print("INTRUSION:   %-34s closest camera approach %.2f m" % [d.name, closest])
	print("INTRUSION: screenshots written: %d" % _shots)
