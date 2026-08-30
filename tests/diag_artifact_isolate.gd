extends Node3D

## v0.9.2.2: reproduce the artifact from the QA recording, then isolate it.
##
## The recording shows a large white/grey angular slab entering view with hard
## black angular wedges radiating across the pitch. My v0.9.2 playtest
## screenshots contain the same thing near a goal, which I wrongly dismissed
## at the time as "the void beyond the pitch edge" -- so it reproduces here
## and there is no need to guess from compressed video.
##
## This renders the SAME static view repeatedly, changing exactly one thing
## each time, and measures every result. Whichever single change removes the
## black wedges names the cause.
##
## Hiding geometry here is a MEASUREMENT, not a fix: the point is to find out
## what the thing is, and nothing hidden by this file ships.
##
## Run windowed:
##   DISPLAY=:88 XDG_RUNTIME_DIR=/tmp/xdgrun LIBGL_ALWAYS_SOFTWARE=1 \
##     godot --path . --rendering-driver opengl3 --display-driver x11 \
##     tests/DiagArtifactIsolate.tscn

const MainScene := preload("res://scenes/Main.tscn")
const SHOT_DIR := "user://v0922_isolate"
const STEP := 3

var main: Node3D
var _cam: Camera3D


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	main = MainScene.instantiate()
	add_child(main)
	for i in range(60):
		await get_tree().physics_frame

	# Freeze the match so every variant renders the identical scene: the only
	# difference between shots is the one thing each variant changes.
	_freeze()
	_place_camera()
	await get_tree().physics_frame

	print("ARTIFACT-ISO: variant | dark_frac | bright_frac | note")
	await _shot("00_baseline", func(): pass)
	await _shot("01_light_shadow_off", func(): _set_light_shadow(false))
	await _shot("02_light_shadow_back_on", func(): _set_light_shadow(true))
	await _shot("03_goals_hidden", func(): _hide_group(["Goal"], false))
	await _shot("04_goals_shown", func(): _hide_group(["Goal"], true))
	await _shot("05_stands_hidden", func(): _hide_group(["Stand"], false))
	await _shot("06_stands_shown", func(): _hide_group(["Stand"], true))
	await _shot("07_walls_hidden", func(): _hide_group(["Wall"], false))
	await _shot("08_walls_shown", func(): _hide_group(["Wall"], true))
	await _shot("09_players_hidden", func(): _hide_players(false))
	await _shot("10_players_shown", func(): _hide_players(true))
	await _shot("11_player_shadows_off", func(): _player_shadows(false))
	await _shot("12_player_shadows_on", func(): _player_shadows(true))

	_dump_visible()
	get_tree().quit()


## Stop the simulation so the scene is identical across variants.
func _freeze() -> void:
	for p in main.home_players + main.away_players:
		p.set_physics_process(false)
		p.set_process(false)
	if main.ball:
		main.ball.freeze = true


## Put the camera where the recording's camera was: elevated, behind play,
## looking toward a goal. This is the game's own rig offset (0, 9, 7) with its
## -50 degree pitch, moved down the pitch so a goal is in frame.
func _place_camera() -> void:
	_cam = get_viewport().get_camera_3d()
	if _cam == null:
		return
	var goal := Vector3(FormationManager.GOAL_LINE_X, 0.0, 0.0)
	var from: Vector3 = goal * 0.45 + Vector3(0, 9, 7)
	_cam.global_position = from
	_cam.look_at(goal * 0.75 + Vector3(0, 1.0, 0))


func _shot(label: String, change: Callable) -> void:
	change.call()
	await get_tree().physics_frame
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path("%s/%s.png" % [SHOT_DIR, label]))
	var m: Dictionary = _measure(img)
	print("ARTIFACT-ISO: %-26s | %9.4f | %11.4f |" % [label, m["dark"], m["bright"]])


## The artifact has two signatures in the recording: hard near-black wedges,
## and a large white/grey slab. Both are measured, because whichever one a
## variant removes is the one it explains.
func _measure(img: Image) -> Dictionary:
	var dark := 0
	var bright := 0
	var total := 0
	for y in range(0, img.get_height(), STEP):
		for x in range(0, img.get_width(), STEP):
			total += 1
			var c: Color = img.get_pixel(x, y)
			var lum: float = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			if lum < 0.20:
				dark += 1
			# White/grey: bright AND desaturated, so the green pitch and the
			# coloured UI do not count.
			elif lum > 0.55 and maxf(c.r, maxf(c.g, c.b)) - minf(c.r, minf(c.g, c.b)) < 0.12:
				bright += 1
	return {"dark": float(dark) / total, "bright": float(bright) / total}


func _set_light_shadow(on: bool) -> void:
	for n in _all(main):
		if n is DirectionalLight3D:
			(n as DirectionalLight3D).shadow_enabled = on


func _hide_group(prefixes: Array, visible: bool) -> void:
	for n in _all(main):
		if not (n is VisualInstance3D):
			continue
		var path: String = str(main.get_path_to(n))
		for p in prefixes:
			if path.contains(p):
				(n as VisualInstance3D).visible = visible
				break


func _hide_players(visible: bool) -> void:
	for p in main.home_players + main.away_players:
		p.visible = visible


func _player_shadows(on: bool) -> void:
	for p in main.home_players + main.away_players:
		for n in _all(p):
			if n is GeometryInstance3D:
				(n as GeometryInstance3D).cast_shadow = \
					GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on \
					else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Everything the camera can currently see, biggest first, so the slab in the
## recording can be named rather than described.
func _dump_visible() -> void:
	print("ARTIFACT-ISO: ---- visible geometry in frame, largest first ----")
	var rows: Array = []
	for n in _all(main):
		var vi := n as VisualInstance3D
		if vi == null or not vi.is_visible_in_tree():
			continue
		var aabb: AABB = vi.get_aabb()
		var size: Vector3 = vi.global_transform.basis * aabb.size
		var centre: Vector3 = vi.global_transform * aabb.get_center()
		if _cam != null and _cam.is_position_behind(centre):
			continue
		rows.append({
			"size": size.length(),
			"path": str(main.get_path_to(vi)),
			"dist": centre.distance_to(_cam.global_position) if _cam else -1.0,
		})
	rows.sort_custom(func(a, b): return a["size"] > b["size"])
	for r in rows.slice(0, 16):
		print("ARTIFACT-ISO:  %9.2fm  dist %7.2f  %s" % [r["size"], r["dist"], r["path"]])


func _all(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out
