extends Node3D

## v0.9.2.1: catch the artifact in the act (brief section 1).
##
## The bone scan ruled out a flung bone, and four screenshots taken seconds
## apart cannot show something that flickers. So this captures CONSECUTIVE
## frames from the real gameplay camera, measures each one, and keeps the
## outliers -- plus a dump of what geometry was in front of the camera at that
## instant, so an anomalous frame names its own cause.
##
## Two measures, because the report ("large object", "obstructs gameplay")
## could be either:
##
##   dark_frac   fraction of the frame that is nearly black. A large occluding
##               object between camera and pitch shows up here whether it
##               flickers or not.
##   delta_frac  fraction of pixels that changed a lot since the previous
##               frame. This is what catches something appearing for one frame
##               and vanishing, which no still image would show.
##
## The camera is the game's own, and the controlled player is driven for part
## of the run and left still for the rest, because QA saw it in both.
##
## Run windowed:
##   DISPLAY=:88 XDG_RUNTIME_DIR=/tmp/xdgrun LIBGL_ALWAYS_SOFTWARE=1 \
##     godot --path . --rendering-driver opengl3 --display-driver x11 \
##     tests/DiagArtifactFrames.tscn

const MainScene := preload("res://scenes/Main.tscn")
const SHOT_DIR := "user://v0921_artifact"
const MOVING_FRAMES := 150
const STILL_FRAMES := 150
## Sample every Nth pixel; full-resolution scanning in GDScript is far too slow.
const STEP := 4

var main: Node3D
var _prev: Image = null
var _rows: Array = []


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	main = MainScene.instantiate()
	add_child(main)
	for i in range(90):
		await get_tree().physics_frame

	print("ARTIFACT: phase 1 -- controlled player MOVING")
	await _capture(MOVING_FRAMES, true)
	print("ARTIFACT: phase 2 -- controlled player STILL")
	await _capture(STILL_FRAMES, false)

	_report()
	get_tree().quit()


func _capture(frames: int, moving: bool) -> void:
	var human: FootballPlayer = _human()
	for i in range(frames):
		if human != null and is_instance_valid(human):
			human.move_input = Vector2(sin(i * 0.05), cos(i * 0.035)) if moving else Vector2.ZERO
		await get_tree().physics_frame
		await RenderingServer.frame_post_draw
		var img: Image = get_viewport().get_texture().get_image()
		var m: Dictionary = _measure(img)
		m["frame"] = i
		m["phase"] = "moving" if moving else "still"
		m["img"] = img
		_rows.append(m)
		_prev = img


## Fraction nearly black, and fraction changed a lot since the previous frame.
func _measure(img: Image) -> Dictionary:
	var w: int = img.get_width()
	var h: int = img.get_height()
	var dark := 0
	var changed := 0
	var total := 0
	for y in range(0, h, STEP):
		for x in range(0, w, STEP):
			total += 1
			var c: Color = img.get_pixel(x, y)
			if c.r < 0.09 and c.g < 0.09 and c.b < 0.09:
				dark += 1
			if _prev != null:
				var p: Color = _prev.get_pixel(x, y)
				if absf(c.r - p.r) + absf(c.g - p.g) + absf(c.b - p.b) > 0.45:
					changed += 1
	return {
		"dark": float(dark) / maxf(total, 1),
		"delta": float(changed) / maxf(total, 1) if _prev != null else 0.0,
	}


func _report() -> void:
	if _rows.is_empty():
		print("ARTIFACT: no frames")
		return

	for phase in ["moving", "still"]:
		var dark: Array = []
		var delta: Array = []
		for r in _rows:
			if r["phase"] != phase:
				continue
			dark.append(r["dark"])
			delta.append(r["delta"])
		if dark.is_empty():
			continue
		dark.sort()
		delta.sort()
		var n: int = dark.size()
		print("ARTIFACT: %-6s dark  median %.3f  p90 %.3f  max %.3f" % [
			phase, dark[n / 2], dark[int(n * 0.9)], dark[n - 1]])
		print("ARTIFACT: %-6s delta median %.3f  p90 %.3f  max %.3f" % [
			phase, delta[n / 2], delta[int(n * 0.9)], delta[n - 1]])

	# Keep the extremes of each measure, plus their neighbours, so a one-frame
	# flash can be compared against the frames either side of it.
	var by_dark: Array = _rows.duplicate()
	by_dark.sort_custom(func(a, b): return a["dark"] > b["dark"])
	var by_delta: Array = _rows.duplicate()
	by_delta.sort_custom(func(a, b): return a["delta"] > b["delta"])

	_save(by_dark[0], "worst_dark")
	_save(by_delta[0], "worst_delta")
	var idx: int = _rows.find(by_delta[0])
	if idx > 0:
		_save(_rows[idx - 1], "before_worst_delta")
	if idx >= 0 and idx + 1 < _rows.size():
		_save(_rows[idx + 1], "after_worst_delta")
	print("ARTIFACT: worst dark  %.3f at %s frame %d" % [
		by_dark[0]["dark"], by_dark[0]["phase"], by_dark[0]["frame"]])
	print("ARTIFACT: worst delta %.3f at %s frame %d" % [
		by_delta[0]["delta"], by_delta[0]["phase"], by_delta[0]["frame"]])

	_dump_geometry()


func _save(row: Dictionary, label: String) -> void:
	var path: String = "%s/%s_%s_%d.png" % [SHOT_DIR, label, row["phase"], row["frame"]]
	(row["img"] as Image).save_png(ProjectSettings.globalize_path(path))
	print("ARTIFACT: saved %s (dark %.3f delta %.3f)" % [
		ProjectSettings.globalize_path(path), row["dark"], row["delta"]])


## Everything drawable in the scene, biggest world-space bounds first.
##
## A "large object obstructing the view" has to be large somewhere. This lists
## what could possibly be it, by name and size, so the answer is a node path
## rather than a theory.
func _dump_geometry() -> void:
	var cam: Camera3D = get_viewport().get_camera_3d()
	print("ARTIFACT: ---- drawable geometry, largest first ----")
	if cam != null:
		print("ARTIFACT: camera at %s near=%.3f far=%.1f fov=%.1f" % [
			cam.global_position, cam.near, cam.far, cam.fov])
	var found: Array = []
	_collect(main, found)
	found.sort_custom(func(a, b): return a["size"] > b["size"])
	for e in found.slice(0, 14):
		print("ARTIFACT:  %8.2fm  %-52s dist %6.2f  %s" % [
			e["size"], e["path"], e["dist"], e["type"]])


func _collect(n: Node, out: Array) -> void:
	var cam: Camera3D = get_viewport().get_camera_3d()
	if n is VisualInstance3D and (n as VisualInstance3D).visible:
		var vi := n as VisualInstance3D
		var aabb: AABB = vi.get_aabb()
		var world: Vector3 = vi.global_transform.basis * aabb.size
		out.append({
			"size": world.length(),
			"path": str(main.get_path_to(vi)).substr(0, 52),
			"type": vi.get_class(),
			"dist": vi.global_position.distance_to(cam.global_position) if cam else -1.0,
		})
	for c in n.get_children():
		_collect(c, out)


## The player the game camera is following, which is the perspective QA
## reported the artifact from.
func _human() -> FootballPlayer:
	var pc: Node = main.get_node_or_null("PlayerController")
	if pc != null and pc.get("controlled_player") != null:
		return pc.controlled_player
	return main.home_players[0] if not main.home_players.is_empty() else null
