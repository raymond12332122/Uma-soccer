extends Node3D

## DEV ONLY. Names the node that produced a given pixel.
##
## Every previous artifact investigation reasoned from a proxy -- dark
## fraction, bounding volumes, ray-grid coverage against AABBs. Each proxy
## found something real and each one also missed something real, because none
## of them looked at the pixels the renderer actually produced.
##
## This does. Alongside the ordinary frame it renders an ID PASS: every logical
## object in the scene is given a unique flat unshaded colour, the sky is
## flattened to black and the UI is hidden. Histogramming that image gives the
## EXACT screen-space coverage of every object, with no bounding-box
## approximation anywhere -- and lets any suspicious region of the real frame
## be traced back to the node that drew it.
##
## "Logical object" is deliberately coarser than MeshInstance3D: a character's
## dozen sub-meshes share one id, because the question is "which THING is on
## screen", not "which submesh". Stadium pieces are individual.
##
## Nothing here ships. It is a diagnostic scene; the shipped scenes are never
## modified, the overrides are applied and removed inside a single capture, and
## no debug material survives the frame it was drawn on.

const MainScene := preload("res://scenes/Main.tscn")

const SECONDS := 120
const CAPTURE_EVERY := 12
const SAMPLE_STEP := 3

## SWEEP mode drives the camera rig through every pose the follow logic can
## reach while the match plays underneath, instead of hoping a match wanders
## to the ends. A 60-second AI-v-AI match kept the camera between x 10 and 15;
## the goals are at x +-29, so the poses QA reports the artifact from were
## never visited at all. Both modes are needed: the sweep proves the worst
## case exists or does not, the live match proves what actually happens.
const SWEEP := true
const SWEEP_X := [-34.0, -32.0, -29.0, -25.0, -20.0, -14.0, 0.0, 14.0, 20.0, 25.0, 29.0, 32.0, 34.0]
const SWEEP_Z := [-24.0, -20.0, -14.0, -7.0, 0.0, 7.0, 14.0, 20.0, 24.0]
const SWEEP_SETTLE := 3

## Coverage above which an object is worth capturing the real frame for.
## The ground legitimately fills the lower half, so it is excluded by name.
const FLAG_COVERAGE := 0.12

const SHOT_DIR := "user://objectid"

## Six well-separated levels per channel. Well separated so that whatever the
## renderer does to a colour on its way to the framebuffer -- sRGB conversion,
## tonemapping -- nearest-match on read-back still lands on the right entry.
## Black is reserved for "background / nothing".
const LEVELS := [0, 51, 102, 153, 204, 255]

var _main: Node3D
var _camera: Camera3D
var _ui: CanvasLayer
var _env: Environment

## id index -> {name, colour, meshes, owner}
var _objects: Array = []
## packed colour key -> id index
var _by_colour := {}

var _flat := StandardMaterial3D.new()
var _frame := 0
var _shots := 0

## Per-object maximum coverage seen, and where.
var _peak := {}
var _calibrated := false


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	_main = MainScene.instantiate()
	add_child(_main)
	for i in range(90):
		await get_tree().process_frame

	_camera = get_viewport().get_camera_3d()
	_ui = _main.get_node_or_null("UI")
	var we: WorldEnvironment = _main.get_node_or_null("WorldEnvironment")
	_env = we.environment if we != null else null

	_build_registry()
	print("OBJID: %d logical objects registered" % _objects.size())
	var vp: Vector2 = get_viewport().get_visible_rect().size
	print("OBJID: viewport %dx%d, capturing every %d frames for %ds" % [
		int(vp.x), int(vp.y), CAPTURE_EVERY, SECONDS])

	if SWEEP:
		var rig: Node3D = _camera.get_parent()
		if rig.has_method("set_target"):
			rig.set_target(null)
			rig.set_ball(null)
		rig.set_process(false)
		print("OBJID: sweep mode -- %d poses, match running underneath" % [
			SWEEP_X.size() * SWEEP_Z.size()])
		for sx in SWEEP_X:
			for sz in SWEEP_Z:
				# Drive the rig to the extreme the follow logic could ask for,
				# then apply the SHIPPED containment. This measures what the
				# real camera can produce, not what an unclamped rig can.
				rig.global_position = Vector3(sx, 0.0, sz)
				if rig.has_method("_contain"):
					rig._contain()
				for i in range(SWEEP_SETTLE):
					await get_tree().process_frame
					_frame += 1
				await _capture()
	else:
		for i in range(SECONDS * 60):
			await get_tree().process_frame
			_frame += 1
			if _frame % CAPTURE_EVERY == 0:
				await _capture()

	_report()
	get_tree().quit()


# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

func _build_registry() -> void:
	# Characters: one id each, covering every mesh they own.
	var players: Node = _main.get_node_or_null("Players")
	if players != null:
		for child in players.get_children():
			var meshes: Array = []
			_meshes_of(child, meshes)
			if not meshes.is_empty():
				_add_object("PLAYER:%s" % child.name, meshes, child)

	# The ball.
	var ball: Node = _main.get_node_or_null("Ball")
	if ball != null:
		var bm: Array = []
		_meshes_of(ball, bm)
		if not bm.is_empty():
			_add_object("BALL", bm, ball)

	# Stadium: every direct child of Field gets its own id, so a goal post and
	# a goal net and a stand tier are all separately nameable.
	var field: Node = _main.get_node_or_null("Field")
	if field != null:
		for child in field.get_children():
			var meshes: Array = []
			_meshes_of(child, meshes)
			if not meshes.is_empty():
				_add_object("FIELD:%s" % child.name, meshes, child)

	# Anything else that draws, so nothing can hide from this.
	var claimed := {}
	for o in _objects:
		for m in o["meshes"]:
			claimed[m.get_instance_id()] = true
	var rest: Array = []
	_meshes_of(_main, rest)
	for m in rest:
		if not claimed.has(m.get_instance_id()):
			_add_object("OTHER:%s" % m.name, [m], m)


func _add_object(name: String, meshes: Array, owner: Node) -> void:
	var idx: int = _objects.size()
	var col: Color = _colour_for(idx)
	_objects.append({"name": name, "colour": col, "meshes": meshes, "owner": owner})
	_by_colour[_key(col)] = idx


## Index -> palette colour, skipping pure black (reserved for background).
func _colour_for(idx: int) -> Color:
	var n: int = idx + 1
	var b: int = LEVELS[n % LEVELS.size()]
	var g: int = LEVELS[(n / LEVELS.size()) % LEVELS.size()]
	var r: int = LEVELS[(n / (LEVELS.size() * LEVELS.size())) % LEVELS.size()]
	return Color8(r, g, b)


func _key(c: Color) -> int:
	return (_nearest(c.r8) << 16) | (_nearest(c.g8) << 8) | _nearest(c.b8)


## Snap a read-back channel to the nearest palette level.
func _nearest(v: int) -> int:
	var best: int = LEVELS[0]
	var best_d: int = 999
	for l in LEVELS:
		var d: int = absi(l - v)
		if d < best_d:
			best_d = d
			best = l
	return best


func _meshes_of(n: Node, out: Array) -> void:
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		_meshes_of(c, out)


# ---------------------------------------------------------------------------
# Capture
# ---------------------------------------------------------------------------

func _capture() -> void:
	# The real frame first, exactly as a player sees it.
	var real: Image = get_viewport().get_texture().get_image()

	# Then the same instant, re-rendered as flat ids.
	var saved_bg: int = -1
	var saved_col := Color.BLACK
	var saved_amb: int = -1
	if _env != null:
		saved_bg = _env.background_mode
		saved_col = _env.background_color
		saved_amb = _env.ambient_light_source
		_env.background_mode = Environment.BG_COLOR
		_env.background_color = Color.BLACK
		_env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	if _ui != null:
		_ui.visible = false

	_flat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for o in _objects:
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = o["colour"]
		o["mat"] = mat
		for m in o["meshes"]:
			if is_instance_valid(m):
				m.material_override = mat

	await get_tree().process_frame
	await get_tree().process_frame
	var ids: Image = get_viewport().get_texture().get_image()

	for o in _objects:
		for m in o["meshes"]:
			if is_instance_valid(m):
				m.material_override = null
	if _ui != null:
		_ui.visible = true
	if _env != null:
		_env.background_mode = saved_bg
		_env.background_color = saved_col
		_env.ambient_light_source = saved_amb

	_analyse(real, ids)


func _analyse(real: Image, ids: Image) -> void:
	var w: int = ids.get_width()
	var h: int = ids.get_height()
	var counts := {}
	var unmatched := 0
	var total := 0
	# Read the raw byte buffer rather than calling get_pixel per sample.
	# get_pixel through GDScript made a single capture cost more than a second
	# of gameplay, which put a full match out of reach; this is the same
	# measurement at a fraction of the cost.
	if ids.get_format() != Image.FORMAT_RGBA8:
		ids.convert(Image.FORMAT_RGBA8)
	var buf: PackedByteArray = ids.get_data()
	var stride: int = w * 4
	var y: int = 0
	while y < h:
		var row: int = y * stride
		var x: int = 0
		while x < w:
			var i: int = row + x * 4
			total += 1
			var r: int = buf[i]
			var g: int = buf[i + 1]
			var b: int = buf[i + 2]
			if r < 26 and g < 26 and b < 26:
				x += SAMPLE_STEP
				continue  # background
			var k: int = (_nearest(r) << 16) | (_nearest(g) << 8) | _nearest(b)
			if _by_colour.has(k):
				counts[_by_colour[k]] = counts.get(_by_colour[k], 0) + 1
			else:
				unmatched += 1
			x += SAMPLE_STEP
		y += SAMPLE_STEP

	if not _calibrated:
		_calibrated = true
		print("OBJID: calibration -- %d of %d sampled pixels matched no id (%.2f%%)" % [
			unmatched, total, 100.0 * unmatched / maxf(total, 1)])

	# Rank this frame.
	var ranked: Array = counts.keys()
	ranked.sort_custom(func(a, b): return counts[a] > counts[b])
	var cam: Vector3 = _camera.global_position

	var worst_idx := -1
	var worst_cover := 0.0
	var top: Array = []
	for idx in ranked:
		var cover: float = float(counts[idx]) / float(maxi(total, 1))
		var nm: String = _objects[idx]["name"]
		if top.size() < 3:
			top.append("%s %.1f%%" % [nm, cover * 100.0])
		var prev: float = float(_peak.get(nm, {}).get("cover", 0.0))
		if cover > prev:
			_peak[nm] = {"cover": cover, "frame": _frame, "cam": cam}
		if nm != "FIELD:Ground" and cover > worst_cover:
			worst_cover = cover
			worst_idx = idx

	print("OBJID: f%05d cam(%.1f, %.1f, %.1f)  %s" % [
		_frame, cam.x, cam.y, cam.z, ", ".join(top)])

	if worst_idx >= 0 and worst_cover >= FLAG_COVERAGE and _shots < 24:
		_shots += 1
		var nm: String = _objects[worst_idx]["name"]
		var safe: String = nm.replace(":", "_").replace("/", "_")
		real.save_png("%s/f%05d_%s_%02d_real.png" % [SHOT_DIR, _frame, safe, int(worst_cover * 100)])
		ids.save_png("%s/f%05d_%s_%02d_ids.png" % [SHOT_DIR, _frame, safe, int(worst_cover * 100)])
		_describe(worst_idx, worst_cover)


## Everything the brief asks to be recorded at a suspicious frame.
func _describe(idx: int, cover: float) -> void:
	var o: Dictionary = _objects[idx]
	var owner: Node = o["owner"]
	var cam: Vector3 = _camera.global_position
	print("OBJID: >>> %s covers %.1f%% of the frame" % [o["name"], cover * 100.0])
	print("OBJID:     owner path %s" % owner.get_path())
	for m in o["meshes"]:
		if not is_instance_valid(m) or not m.is_visible_in_tree():
			continue
		var xf: Transform3D = m.global_transform
		var world: AABB = xf * m.get_aabb()
		var custom: AABB = m.custom_aabb
		var eff: AABB = xf * (custom if custom.size.length() > 0.0001 else m.get_aabb())
		var mat: Material = m.get_active_material(0)
		print("OBJID:     mesh %s" % m.get_path())
		print("OBJID:       origin (%.2f, %.2f, %.2f) scale (%.2f, %.2f, %.2f) dist %.2f m" % [
			xf.origin.x, xf.origin.y, xf.origin.z,
			xf.basis.get_scale().x, xf.basis.get_scale().y, xf.basis.get_scale().z,
			cam.distance_to(eff.get_center())])
		print("OBJID:       effective world bounds pos (%.2f, %.2f, %.2f) size (%.2f, %.2f, %.2f)" % [
			eff.position.x, eff.position.y, eff.position.z,
			eff.size.x, eff.size.y, eff.size.z])
		print("OBJID:       raw mesh bounds size (%.2f, %.2f, %.2f), material %s" % [
			world.size.x, world.size.y, world.size.z,
			("none" if mat == null else mat.get_class())])
		break  # one representative mesh is enough to identify the thing
	if o["name"].begins_with("PLAYER:"):
		print("OBJID:     %s" % _character_state(owner))


func _character_state(p: Node) -> String:
	var ac = p.get("animation_controller")
	var skel: Skeleton3D = null
	var stack: Array = [p]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Skeleton3D:
			skel = n
			break
		for c in n.get_children():
			stack.append(c)
	var span := "n/a"
	if skel != null:
		var lo := Vector3(INF, INF, INF)
		var hi := Vector3(-INF, -INF, -INF)
		for b in range(skel.get_bone_count()):
			var v: Vector3 = skel.get_bone_global_pose(b).origin
			if not (is_finite(v.x) and is_finite(v.y) and is_finite(v.z)):
				return "NON-FINITE BONE %d" % b
			lo = Vector3(minf(lo.x, v.x), minf(lo.y, v.y), minf(lo.z, v.z))
			hi = Vector3(maxf(hi.x, v.x), maxf(hi.y, v.y), maxf(hi.z, v.z))
		span = "bone span (%.2f, %.2f, %.2f)" % [hi.x - lo.x, hi.y - lo.y, hi.z - lo.z]
	return "action=%s %s" % [("?" if ac == null else str(ac.get("last_action"))), span]


func _report() -> void:
	print("OBJID: ================ RESULT ================")
	print("OBJID: %d frames, %d captures, %d flagged" % [
		_frame, _frame / CAPTURE_EVERY, _shots])
	print("OBJID: ---- largest TRUE screen coverage ever reached, per object ----")
	var keys: Array = _peak.keys()
	keys.sort_custom(func(a, b): return _peak[a]["cover"] > _peak[b]["cover"])
	for k in keys:
		var e: Dictionary = _peak[k]
		if e["cover"] < 0.01:
			continue
		print("OBJID:   %6.2f%%  %-34s  at f%05d camera (%.1f, %.1f, %.1f)" % [
			e["cover"] * 100.0, k, e["frame"], e["cam"].x, e["cam"].y, e["cam"].z])
