extends Node3D

## Blocker 3: fall / collision / recovery synchronisation.
##
## The defect, measured before the fix (tests/diag_recovery_sync.gd):
##
##   control returned at frame        77    STUMBLE_TIME 1.30 s x 60
##   the get-up clip finished at      176   its 1.65 s tail, 99 frames later
##   distance sprinted while rising   9.68 m
##
## Movement unlocked when the DOWN timers expired, and `get_up` was fired on
## that same frame -- so the recovery clip played from frame zero while the
## player was already free to sprint.
##
## Getting up is now a phase that owns the body until it is genuinely
## finished, and "finished" is a property of the animation rather than of a
## timer running beside it. These checks cover every way that could go wrong:
## a human holding the stick, an AI-driven player, half-speed playback, a rig
## with no clips at all, being knocked down again mid-rise, a slide recovery
## rather than a foul, and a match reset.

const MainScene := preload("res://scenes/Main.tscn")

var _passed := 0
var _failed := 0


func _ready() -> void:
	print("V1_0_REC: ==== fall / recovery synchronisation ====")
	_test_constants()
	await _test_no_movement_while_rising("human input", true)
	await _test_no_movement_while_rising("no input", false)
	await _test_half_speed_extends_the_hold()
	await _test_missing_animation_still_gets_up()
	await _test_knocked_down_again_mid_rise()
	await _test_slide_recovery_also_holds()
	await _test_match_reset_clears_recovery()
	print("V1_0_REC: ==== %d passed, %d failed ====" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, label: String) -> void:
	if ok:
		_passed += 1
		print("V1_0_REC: PASS  %s" % label)
	else:
		_failed += 1
		print("V1_0_REC: FAIL  %s" % label)


func _test_constants() -> void:
	_check(FootballPlayer.RISING_MIN_HOLD < FootballPlayer.RISING_FALLBACK,
		"the anti-race floor is shorter than the no-animation hold")
	_check(FootballPlayer.RISING_LIMIT_SCALE >= 2.0,
		"the safety ceiling leaves room for at least half-speed playback")


# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

## One isolated player in a real match, with the AI and human input off so the
## scenario decides what happens.
func _stage() -> Dictionary:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(40):
		await get_tree().physics_frame
	main.home_team.set_physics_process(false)
	main.away_team.set_physics_process(false)
	if main.player_controller != null:
		main.player_controller.set_physics_process(false)

	var victim: FootballPlayer = main.home_players[5]
	var i2 := 0
	for p in (main.home_players + main.away_players):
		if p == victim:
			continue
		p.movement_locked = true
		p.move_input = Vector2.ZERO
		p.global_position = Vector3(-30.0 + float(i2) * 3.0, p.global_position.y, -21.0)
		i2 += 1
	victim.global_position = Vector3(0, victim.global_position.y, 0)
	main.ball.global_position = Vector3(8, 0.16, 8)
	main.ball.linear_velocity = Vector3.ZERO
	for i in range(15):
		await get_tree().physics_frame
	return {"main": main, "victim": victim}


func _teardown(ctx: Dictionary) -> void:
	var main = ctx.get("main")
	if main != null and is_instance_valid(main):
		main.get_parent().remove_child(main)
		main.queue_free()
	for i in range(3):
		await get_tree().physics_frame


## Run a knockdown and report what happened. `drive` holds the stick down.
func _knockdown(victim: FootballPlayer, drive: bool, budget: int = 600) -> Dictionary:
	var start: Vector3 = victim.global_position
	victim.begin_stumble(SlideTackle.STUMBLE_TIME)
	var moved_while_locked := 0.0
	var last: Vector3 = victim.global_position
	var release := -1
	var ever_rising := false
	for f in range(budget):
		if drive:
			victim.move_input = Vector2(1, 0)
			victim.sprint_requested = true
		await get_tree().physics_frame
		if victim.is_rising:
			ever_rising = true
		if victim.is_recovering():
			moved_while_locked += Vector2(
				victim.global_position.x - last.x,
				victim.global_position.z - last.z).length()
		elif release < 0:
			release = f
			break
		last = victim.global_position
	return {
		"release": release,
		"moved_while_locked": moved_while_locked,
		"ever_rising": ever_rising,
		"total": Vector2(victim.global_position.x - start.x,
			victim.global_position.z - start.z).length(),
	}


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

func _test_no_movement_while_rising(label: String, drive: bool) -> void:
	var ctx: Dictionary = await _stage()
	var r: Dictionary = await _knockdown(ctx["victim"], drive)
	print("V1_0_REC: [%s] released at frame %d, moved %.3f m while locked" % [
		label, r["release"], r["moved_while_locked"]])
	_check(r["ever_rising"], "[%s] the player entered a rising phase at all" % label)
	_check(r["release"] > 150,
		"[%s] control is held past the old frame-77 unlock (released %d)" % [
			label, r["release"]])
	_check(r["moved_while_locked"] < 0.05,
		"[%s] zero planar movement while down or rising (%.3f m)" % [
			label, r["moved_while_locked"]])
	await _teardown(ctx)


## The property that separates an authoritative recovery from a tuned timer:
## slow the clip down and the hold has to follow it.
func _test_half_speed_extends_the_hold() -> void:
	var full: Dictionary = await _stage()
	var r_full: Dictionary = await _knockdown(full["victim"], true)
	await _teardown(full)

	var half: Dictionary = await _stage()
	var victim: FootballPlayer = half["victim"]
	var tree: AnimationTree = victim.animation_controller.get_node_or_null("AnimationTree")
	_check(tree != null, "the action branch is rate-controllable for this test")
	if tree != null:
		tree.set("parameters/ActionScale/scale", 0.5)
	var r_half: Dictionary = await _knockdown(victim, true, 900)
	print("V1_0_REC: [half speed] full-rate release %d, half-rate release %d" % [
		r_full["release"], r_half["release"]])
	_check(r_half["release"] > r_full["release"] + 40,
		"a half-speed get-up holds control materially longer (%d vs %d)" % [
			r_half["release"], r_full["release"]])
	_check(r_half["moved_while_locked"] < 0.05,
		"...and still moves nothing while locked (%.3f m)" % r_half["moved_while_locked"])
	await _teardown(half)


## No clips at all must not freeze anybody. Section 9 of the animation brief:
## no reaction may permanently freeze control or AI.
func _test_missing_animation_still_gets_up() -> void:
	var ctx: Dictionary = await _stage()
	var victim: FootballPlayer = ctx["victim"]
	# Strip the animation layer entirely, the way a rig with no library behaves.
	victim.animation_controller = null
	var r: Dictionary = await _knockdown(victim, true)
	print("V1_0_REC: [no animation] released at frame %d" % r["release"])
	_check(r["release"] > 0, "a player with no animation layer still gets up")
	_check(r["release"] < 300,
		"...promptly, on the fallback hold rather than the safety ceiling (%d)" % r["release"])
	_check(r["moved_while_locked"] < 0.05,
		"...and does not move while doing it (%.3f m)" % r["moved_while_locked"])
	await _teardown(ctx)


## Interrupting a recovery has to be possible: a second challenge while
## somebody is picking themselves up is ordinary football.
func _test_knocked_down_again_mid_rise() -> void:
	var ctx: Dictionary = await _stage()
	var victim: FootballPlayer = ctx["victim"]
	victim.begin_stumble(SlideTackle.STUMBLE_TIME)
	# Run until the rising phase starts.
	var entered := false
	for f in range(400):
		await get_tree().physics_frame
		if victim.is_rising:
			entered = true
			break
	_check(entered, "the rising phase is reachable")
	# ...and knock them straight back down.
	victim.begin_stumble(SlideTackle.STUMBLE_TIME)
	await get_tree().physics_frame
	_check(not victim.is_rising, "a second knockdown cancels the rise")
	_check(victim.stumble_time > 0.0, "...and puts the player back on the floor")

	var released := -1
	for f in range(600):
		await get_tree().physics_frame
		if not victim.is_recovering():
			released = f
			break
	print("V1_0_REC: [interrupted] recovered %d frames after the second knockdown" % released)
	_check(released > 0, "the interrupted player still recovers (no permanent freeze)")
	await _teardown(ctx)


## The same hold must apply to a slide's own recovery, not only to a foul.
func _test_slide_recovery_also_holds() -> void:
	var ctx: Dictionary = await _stage()
	var victim: FootballPlayer = ctx["victim"]
	victim.slide_recovery = 0.5
	var moved := 0.0
	var last: Vector3 = victim.global_position
	var released := -1
	var saw_rising := false
	for f in range(600):
		victim.move_input = Vector2(1, 0)
		victim.sprint_requested = true
		await get_tree().physics_frame
		if victim.is_rising:
			saw_rising = true
		if victim.is_recovering():
			moved += Vector2(victim.global_position.x - last.x,
				victim.global_position.z - last.z).length()
		elif released < 0:
			released = f
			break
		last = victim.global_position
	print("V1_0_REC: [slide recovery] released at frame %d, moved %.3f m while locked" % [
		released, moved])
	_check(saw_rising, "a slide recovery also runs through the rising phase")
	_check(moved < 0.05, "...with no movement while locked (%.3f m)" % moved)
	await _teardown(ctx)


## A reset must not leave anybody serving out a knockdown from play that no
## longer exists.
func _test_match_reset_clears_recovery() -> void:
	var ctx: Dictionary = await _stage()
	var main: Node3D = ctx["main"]
	var victim: FootballPlayer = ctx["victim"]
	victim.begin_stumble(SlideTackle.STUMBLE_TIME)
	await get_tree().physics_frame
	_check(victim.is_recovering(), "the player is genuinely down before the reset")
	main._reset_all_players()
	await get_tree().physics_frame
	_check(not victim.is_recovering(),
		"a match reset clears the recovery outright")
	_check(not victim.is_rising and victim.stumble_time <= 0.0,
		"...including both the floor and the rising phase")
	await _teardown(ctx)
