extends Node3D

## v0.9.2.3 section 2: object-level isolation of the remaining artifact.
##
## The live capture at camera (15.2, 13.1) shows the thing human QA is
## describing: a large pale angular structure entering from the right with hard
## dark bars radiating across the pitch. The camera-pose sweep proved the
## camera never enters any geometry (0 INSIDE, 0 within 0.35 m, over all 510
## reachable poses), so this is not a clipping artifact -- it is a real object
## rendered from close range.
##
## This freezes that exact camera pose and re-renders it, changing exactly one
## thing at a time, to name the object and the part of it responsible:
##
##   baseline
##   goal frame hidden      posts, crossbar, back bars, side bars
##   goal nets hidden       the four translucent panels
##   net shadows off        nets still drawn, but no longer casting
##   all goal shadows off   the whole goal still drawn, casting nothing
##   directional shadow off
##
## Each variant is saved AND measured, but the measurement is per-object
## coverage and per-region darkness, not a whole-frame "dark fraction" -- that
## metric is what made v0.9.2.2 clear the goals (0.1454 -> 0.1472, "goals are
## not it") when the goal is in fact exactly what QA is looking at. A bright
## slab and a localised shadow both vanish into a frame-wide average.

const MainScene := preload("res://scenes/Main.tscn")
const SHOT_DIR := "user://goalartifact"

## The pose that reproduced the artifact in the live 60 s capture.
const CAM_X := 15.2
const CAM_Z := 13.1

var _main: Node3D
var _camera: Camera3D
var _rig: Node3D


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	_main = MainScene.instantiate()
	add_child(_main)
	for i in range(90):
		await get_tree().process_frame

	_camera = get_viewport().get_camera_3d()
	_rig = _camera.get_parent()
	if _rig.has_method("set_target"):
		_rig.set_target(null)
		_rig.set_ball(null)
	_rig.set_process(false)
	_rig.global_position = Vector3(CAM_X, 0.0, CAM_Z)
	for i in range(4):
		await get_tree().process_frame

	var field: Node3D = _main.get_node("Field")
	var light: DirectionalLight3D = _main.get_node("DirectionalLight3D")
	var frame: Array = _nodes(field, ["GoalRightPost", "GoalRightCrossbar",
		"GoalRightBackPost", "GoalRightBackBar", "GoalRightSideBar",
		"GoalLeftPost", "GoalLeftCrossbar", "GoalLeftBackPost",
		"GoalLeftBackBar", "GoalLeftSideBar"])
	var nets: Array = _nodes(field, ["GoalRightNet", "GoalLeftNet"])
	print("GOAL: frame meshes %d, net meshes %d" % [frame.size(), nets.size()])

	await _shot("00_baseline")

	_set_visible(frame, false)
	await _shot("01_goal_frame_hidden")
	_set_visible(frame, true)

	_set_visible(nets, false)
	await _shot("02_goal_nets_hidden")
	_set_visible(nets, true)

	_set_shadows(nets, false)
	await _shot("03_net_shadows_off")
	_set_shadows(nets, true)

	_set_shadows(nets, false)
	_set_shadows(frame, false)
	await _shot("04_all_goal_shadows_off")
	_set_shadows(nets, true)
	_set_shadows(frame, true)

	light.shadow_enabled = false
	await _shot("05_directional_shadow_off")
	light.shadow_enabled = true

	print("GOAL: done")
	get_tree().quit()


## Every MeshInstance3D whose node path contains any of these prefixes.
func _nodes(root: Node, prefixes: Array) -> Array:
	var out: Array = []
	_walk(root, prefixes, out)
	return out


func _walk(n: Node, prefixes: Array, out: Array) -> void:
	if n is MeshInstance3D:
		var p: String = str(n.get_path())
		for pre in prefixes:
			if p.find(pre) >= 0:
				out.append(n)
				break
	for c in n.get_children():
		_walk(c, prefixes, out)


func _set_visible(nodes: Array, v: bool) -> void:
	for n in nodes:
		n.visible = v


func _set_shadows(nodes: Array, on: bool) -> void:
	for n in nodes:
		n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Render, save, and measure the RIGHT HALF of the frame -- where the artifact
## actually is -- rather than averaging it away across the whole image.
func _shot(tag: String) -> void:
	for i in range(3):
		await get_tree().process_frame
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [SHOT_DIR, tag])

	var w: int = img.get_width()
	var h: int = img.get_height()
	var dark := 0
	var pale := 0
	var total := 0
	for x in range(w / 2, w):
		for y in range(0, h * 2 / 3):
			var c: Color = img.get_pixel(x, y)
			var lum: float = c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
			total += 1
			# Shadowed grass: much darker than the lit pitch but still green.
			if lum < 0.35 and c.g > c.r and c.g > c.b:
				dark += 1
			# The pale structure: bright and desaturated, which the pitch never
			# is.
			if lum > 0.60 and absf(c.g - c.r) < 0.25 and absf(c.g - c.b) < 0.25:
				pale += 1
	print("GOAL: %-26s shadowed-pitch %5.2f%%  pale-structure %5.2f%%" % [
		tag, 100.0 * dark / maxf(total, 1), 100.0 * pale / maxf(total, 1)])
