extends Node3D

## v0.9.2: what does animating 22 characters actually cost, and how far out of
## step is a strike clip from the ball leaving? (brief sections 20 and 27)
##
## Both numbers are ones the milestone is required to state rather than
## assert. The performance figure is CPU-side only -- this runs headless, so
## it measures the AnimationTree and skeleton work, not the GPU cost of
## drawing eleven skinned characters, which a phone would also pay.
##
## The A/B is against the SAME match with AnimationLibraryCache disabled, so
## the comparison isolates the animation layer instead of comparing against a
## different scene.

const MainScene := preload("res://scenes/Main.tscn")
const WARMUP_FRAMES := 90
const SAMPLE_SECONDS := 20

## Strikes waiting for their clip to reach full weight.
var _pending: Array = []
var _ball: RigidBody3D = null


func _physics_process(delta: float) -> void:
	_poll_contacts(delta)


func _ready() -> void:
	print("PERF: ==== v0.9.2 animation cost and contact timing ====")

	AnimationLibraryCache.force_disabled = true
	var off: Dictionary = await _run("animation OFF (procedural fallback)")
	AnimationLibraryCache.force_disabled = false
	var on: Dictionary = await _run("animation ON (22 AnimationTrees)")

	print("PERF: ---- comparison ----")
	var delta_ms: float = on["frame_ms"] - off["frame_ms"]
	print("PERF: mean frame %.3fms off -> %.3fms on  (%+.3fms, %+.0f%%)" % [
		off["frame_ms"], on["frame_ms"], delta_ms,
		100.0 * delta_ms / maxf(off["frame_ms"], 0.001)])
	print("PERF: worst frame %.3fms off -> %.3fms on" % [off["worst_ms"], on["worst_ms"]])
	print("PERF: animated players: %d off, %d on" % [off["animated"], on["animated"]])
	print("PERF: NOTE headless: CPU animation cost only, no skinned-mesh GPU cost")
	get_tree().quit()


func _run(label: String) -> Dictionary:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(WARMUP_FRAMES):
		await get_tree().physics_frame

	var players: Array = main.home_players + main.away_players
	var animated := 0
	for p in players:
		if p.animation_controller and p.animation_controller.is_animated():
			animated += 1

	# Contact timing (section 27): how long after the gameplay launch does the
	# strike clip actually begin? The clips start AT their measured contact
	# frame, so this delay IS the visual error -- the distance the ball has
	# already travelled when the boot arrives.
	_ball = main.ball
	_pending.clear()
	var launches: Array = []
	for p in players:
		p.ball_touched.connect(_on_touch.bind(p, launches))

	# Engine process + physics time, NOT wall time between ticks. Timing the
	# gap around `await physics_frame` measures how long the engine WAITED to
	# hit 60Hz, so it reads a flat 16.66ms whatever the game is doing -- the
	# first version of this reported animation as free because both sides
	# measured the frame limiter.
	var total := 0.0
	var worst := 0.0
	var frames := 0
	var t_start: int = Time.get_ticks_usec()
	for i in range(SAMPLE_SECONDS * 60):
		await get_tree().physics_frame
		var ms: float = 1000.0 * (
			Performance.get_monitor(Performance.TIME_PROCESS)
			+ Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS))
		total += ms
		worst = maxf(worst, ms)
		frames += 1
	var wall: float = (Time.get_ticks_usec() - t_start) / 1000000.0

	print("PERF: %-40s mean %.3fms  worst %.3fms  over %d frames (%.1fs wall)" % [
		label, total / maxf(frames, 1), worst, frames, wall])
	if not launches.is_empty():
		var sum := 0.0
		var mx := 0.0
		for d in launches:
			sum += d
			mx = maxf(mx, d)
		print("PERF:   %d strikes; ball had travelled %.2fm on average by the time the strike clip reached full weight (worst %.2fm)" % [
			launches.size(), sum / launches.size(), mx])

	_pending.clear()
	_ball = null
	main.queue_free()
	await get_tree().physics_frame
	return {
		"frame_ms": total / maxf(frames, 1),
		"worst_ms": worst,
		"animated": animated,
	}


## Open a pending measurement when the ball is struck.
##
## OBSERVED, not derived. An earlier version of this multiplied the table's
## fade_in by the launch speed and printed the product, which is arithmetic on
## a constant dressed up as a measurement -- it could not have detected the
## animation failing to fire at all. This records where the ball was when it
## left, and _poll_contacts() closes the record on the frame the strike clip
## is actually at full weight, so the number includes every real source of
## latency and is zero only if the clip really is on time.
func _on_touch(info: Dictionary, p: FootballPlayer, out: Array) -> void:
	var kind: int = int(info.get("kind", -1))
	if kind != FootballPlayer.TouchKind.PASS and kind != FootballPlayer.TouchKind.SHOT:
		return
	var ac: AnimationController = p.animation_controller
	if ac == null:
		return
	var tree: AnimationTree = ac.get_node_or_null("AnimationTree")
	if tree == null:
		return
	_pending.append({
		"tree": tree,
		"ball": _ball,
		"from": _ball.global_position if _ball else Vector3.ZERO,
		"age": 0.0,
		"out": out,
	})


## Close any pending strike whose clip has reached full weight.
func _poll_contacts(delta: float) -> void:
	for i in range(_pending.size() - 1, -1, -1):
		var e: Dictionary = _pending[i]
		e["age"] += delta
		var tree: AnimationTree = e["tree"]
		var ball: RigidBody3D = e["ball"]
		if not is_instance_valid(tree) or not is_instance_valid(ball) or e["age"] > 0.6:
			_pending.remove_at(i)
			continue
		if tree.get("parameters/Shot/active") \
			and float(tree.get("parameters/Shot/fade_in_remaining")) <= 0.0:
			e["out"].append(e["from"].distance_to(ball.global_position))
			_pending.remove_at(i)
