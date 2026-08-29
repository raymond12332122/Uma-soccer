extends Node3D

## v0.9.2 rendered playtest (brief section 30).
##
## Runs the REAL entry point windowed under Xvfb and captures frames, because
## this milestone's failure modes are ones no headless assertion catches:
## a character rendering at the wrong scale, facing backwards, standing in a
## T-pose while sliding, or running with its legs still. The headless suite
## proves the data is wired correctly; only a picture proves it looks like a
## person.
##
## Alongside the screenshots it measures what the animation layer is actually
## doing across all 22 players -- the spread of playback rates, how much of
## the match is spent in each locomotion direction, and how often an action
## clip is playing -- so the report can describe the state of things rather
## than assert it.
##
## Run windowed:
##   DISPLAY=:88 XDG_RUNTIME_DIR=/tmp/xdgrun LIBGL_ALWAYS_SOFTWARE=1 \
##     godot --path . --rendering-driver opengl3 --display-driver x11 \
##     tests/PlaytestV092.tscn

const MainScene := preload("res://scenes/Main.tscn")

## Short: llvmpipe has no GPU behind it, and every figure below is a rate or a
## distribution, so the conclusions do not depend on the duration.
const SECONDS := 25
const SHOT_DIR := "user://v092_shots"

var main: Node3D
var _rate_samples: Array = []
var _dir_bins := {"forward": 0, "back": 0, "left": 0, "right": 0, "idle": 0}
var _action_frames := 0
var _total_samples := 0
## Per player, the last world position, to measure real ground speed.
var _prev_pos := {}
var _max_speed := 0.0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	main = MainScene.instantiate()
	add_child(main)
	for i in range(90):
		await get_tree().physics_frame

	var players: Array = main.home_players + main.away_players
	print("PLAY092: %d players, %d animated" % [players.size(), _animated_count(players)])
	_report_render_sizes(players)

	var shot_at := [3, 9, 16, 23]
	for second in range(SECONDS):
		for f in range(60):
			await get_tree().physics_frame
		_sample(players)
		if second in shot_at:
			await RenderingServer.frame_post_draw
			var img: Image = get_viewport().get_texture().get_image()
			var path: String = "%s/t%02ds.png" % [SHOT_DIR, second]
			img.save_png(ProjectSettings.globalize_path(path))
			print("PLAY092: captured %s" % ProjectSettings.globalize_path(path))

	_report()
	get_tree().quit()


func _animated_count(players: Array) -> int:
	var n := 0
	for p in players:
		if p.animation_controller and p.animation_controller.is_animated():
			n += 1
	return n


## On-screen size, in world metres and in pixels.
##
## The metres figure is the one that catches the failure this milestone
## nearly shipped: the height auto-fit divides by a measured height, and when
## retargeting changed what that measurement saw, every character would have
## been rendered about a hundred times too small. A number next to the 1.6m
## target says so immediately.
func _report_render_sizes(players: Array) -> void:
	var cam: Camera3D = get_viewport().get_camera_3d()
	var lo := INF
	var hi := 0.0
	for p in players:
		var ac: AnimationController = p.animation_controller
		if ac == null:
			continue
		var visual: Node3D = ac.get_child(0) if ac.get_child_count() > 0 else null
		if visual == null:
			continue
		var h: float = ac.last_measured_height * visual.scale.y
		lo = minf(lo, h)
		hi = maxf(hi, h)
	print("PLAY092: rendered character height %.3f to %.3fm (target %.2fm)" % [
		lo, hi, players[0].animation_controller.target_height])
	if cam != null:
		var head: Vector3 = players[0].global_position + Vector3(0, 1.6, 0)
		var feet: Vector3 = players[0].global_position
		if not cam.is_position_behind(head) and not cam.is_position_behind(feet):
			var px: float = absf(cam.unproject_position(head).y - cam.unproject_position(feet).y)
			print("PLAY092: nearest character occupies %.0f screen pixels tall" % px)


func _sample(players: Array) -> void:
	for p in players:
		var ac: AnimationController = p.animation_controller
		if ac == null or not ac.is_animated():
			continue
		var tree: AnimationTree = ac.get_node_or_null("AnimationTree")
		if tree == null:
			continue
		_total_samples += 1
		var blend: Vector2 = tree.get("parameters/Move/blend_position")
		var amount: float = tree.get("parameters/Loco/blend_amount")
		_rate_samples.append(float(tree.get("parameters/MoveScale/scale")))
		if tree.get("parameters/Shot/active"):
			_action_frames += 1
		if amount < 0.15:
			_dir_bins["idle"] += 1
		elif absf(blend.y) >= absf(blend.x):
			_dir_bins["forward" if blend.y > 0.0 else "back"] += 1
		else:
			_dir_bins["right" if blend.x > 0.0 else "left"] += 1

		var speed: float = Vector2(p.velocity.x, p.velocity.z).length()
		_max_speed = maxf(_max_speed, speed)


func _report() -> void:
	print("PLAY092: ---- what the animation layer did over %ds ----" % SECONDS)
	if _total_samples == 0:
		print("PLAY092: no samples")
		return
	_rate_samples.sort()
	var n: int = _rate_samples.size()
	print("PLAY092: playback rate  median %.2f  p90 %.2f  max %.2f  (clamped to %.2f-%.2f)" % [
		_rate_samples[n / 2], _rate_samples[int(n * 0.9)], _rate_samples[n - 1],
		AnimationSet.RATE_MIN, AnimationSet.RATE_MAX])
	var clamped := 0
	for r in _rate_samples:
		if r >= AnimationSet.RATE_MAX - 0.001:
			clamped += 1
	print("PLAY092: %.0f%% of samples ran into the rate ceiling -- those are the ones that slide" % [
		100.0 * clamped / n])
	print("PLAY092: fastest player observed %.2f m/s (gait covers %.2f m/s at the ceiling)" % [
		_max_speed, AnimationSet.RENDERED_NATURAL_SPEED * AnimationSet.RATE_MAX])
	for k in _dir_bins:
		print("PLAY092:   %-8s %5d (%.0f%%)" % [
			k, _dir_bins[k], 100.0 * _dir_bins[k] / _total_samples])
	print("PLAY092: an action clip was playing on %.1f%% of player-samples" % [
		100.0 * _action_frames / _total_samples])
