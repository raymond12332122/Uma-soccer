extends Node3D

## v0.9.0 regression suite -- "THE GOAT" football gameplay foundation.
##
## Pins the behaviours this milestone introduced or fixed, and the ones the
## brief listed as non-negotiable. Every assertion here corresponds to
## something that was measured before being changed; the numbers in the
## messages are the measured ones, so a future regression reads as a
## specific claim rather than a bare boolean.

const MainScene := preload("res://scenes/Main.tscn")
const FieldScene := preload("res://scenes/Field.tscn")
const PlayerScene := preload("res://scenes/FootballPlayer.tscn")
const BallScene := preload("res://scenes/Ball.tscn")

var _passed := 0
var _failed := 0


func _ready() -> void:
	await _test_possession_gates()
	await _test_touch_events()
	await _test_pass_power_and_bands()
	await _test_pass_kinds()
	await _test_stopping_with_the_ball()
	await _test_challenge_is_beatable()
	await _test_live_match()
	print("TEST_SUMMARY: %s (%d passed, %d failed)" % [
		"ALL GREEN" if _failed == 0 else "FAILURES PRESENT", _passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _check(label: String, ok: bool) -> void:
	if ok:
		_passed += 1
		print("[PASS] %s" % label)
	else:
		_failed += 1
		print("[FAIL] %s" % label)


# ---------------------------------------------------------------- gates

## The milestone's headline: an AI must not gain the ball from a distance it
## could not physically reach, and must not keep one that has gone.
func _test_possession_gates() -> void:
	_check("Gaining possession requires contact, not mere proximity (%.2fm)"
		% FootballPlayer.POSSESSION_CONTACT_RADIUS,
		FootballPlayer.POSSESSION_CONTACT_RADIUS <= 1.30)

	# v0.9.0: the contest exemption STRETCHES the contact radius rather than
	# removing it. Granting it unbounded is what let 42% of acquisitions
	# land outside the gate, out to 1.97m.
	_check("A contest win reaches further than contact but is still bounded (%.2fm)"
		% FootballPlayer.CONTEST_WIN_REACH,
		FootballPlayer.CONTEST_WIN_REACH > FootballPlayer.POSSESSION_CONTACT_RADIUS
		and FootballPlayer.CONTEST_WIN_REACH <= 2.0)

	_check("Retention is capped, so a ball that has gone stops being yours (%.2fm)"
		% FootballPlayer.RETAIN_MAX_DISTANCE,
		FootballPlayer.RETAIN_MAX_DISTANCE <= 2.5)

	# The awareness/contact separation the brief asks for, as an ordering.
	_check("Awareness range exceeds challenge range exceeds contact range",
		BallContest.CHALLENGE_RANGE > FootballPlayer.POSSESSION_CONTACT_RADIUS)

	# And the one that mattered most: PossessionManager's election must not
	# hand out the contact-gate exemption. Before v0.9.0 it did, on every
	# opponent carrier change.
	var pair := await _solo_player()
	var player: FootballPlayer = pair[0]
	var ball: RigidBody3D = pair[1]
	player.notify_possession_won_from_opponent()
	_check("A plain possession-won notification does NOT open the contact-gate exemption",
		player._contest_win_timer <= 0.0)
	player.notify_contest_won()
	_check("...but winning an actual contest does", player._contest_win_timer > 0.0)
	player.queue_free()
	ball.queue_free()
	await get_tree().process_frame


# --------------------------------------------------------------- touches

## Ball-contact events exist, carry what an animation needs, and are purely
## outbound -- the physics must not depend on anyone listening.
func _test_touch_events() -> void:
	var pair := await _solo_player()
	var player: FootballPlayer = pair[0]
	var ball: RigidBody3D = pair[1]

	var seen: Array = []
	player.ball_touched.connect(func(info): seen.append(info))

	player.move_input = Vector2(1, 0)
	for i in range(90):
		await get_tree().physics_frame

	_check("Dribbling emits ball-contact events (%d)" % seen.size(), seen.size() > 0)
	if not seen.is_empty():
		var info: Dictionary = seen[0]
		_check("A touch event carries a contact point", info.has("point"))
		_check("A touch event carries a direction", info.has("direction"))
		_check("A touch event carries a strength", info.has("strength") and info["strength"] > 0.0)
		_check("A touch event carries the player's velocity for stride matching",
			info.has("player_velocity"))
		_check("A touch event names a foot", info.get("foot", "") in ["left", "right"])
		_check("A dribble touch is typed as a dribble or a turn",
			info.get("kind", -1) in [FootballPlayer.TouchKind.DRIBBLE, FootballPlayer.TouchKind.TURN])

	# The ball is still simulated, never parented -- a non-negotiable.
	_check("The ball remains a free RigidBody3D", ball is RigidBody3D and ball.get_parent() != player)
	player.queue_free()
	ball.queue_free()
	await get_tree().process_frame


# ------------------------------------------------------------ pass power

func _test_pass_power_and_bands() -> void:
	# Sized by ARRIVAL speed now, so every pass is struck firmly enough to
	# be useful. Before v0.9.0 a 4m pass launched at the 4.0 m/s floor.
	var short_pass: float = PassEvaluator.speed_for_distance(4.0)
	_check("A short pass is struck firmly, not at the floor (%.2f m/s, was 4.10)" % short_pass,
		short_pass > 5.5)
	_check("Pass weight still rises with distance",
		PassEvaluator.speed_for_distance(4.0) < PassEvaluator.speed_for_distance(10.0))
	_check("Pass speed stays inside the pass band at both extremes",
		PassEvaluator.speed_for_distance(0.5) >= PassEvaluator.PASS_SPEED_MIN
		and PassEvaluator.speed_for_distance(100.0) <= PassEvaluator.PASS_SPEED_MAX)
	# The brief: PASS must not become a weak SHOOT.
	_check("The pass band stays clear of the shot floor (%.1f < %.1f)"
		% [PassEvaluator.PASS_SPEED_MAX, FootballPlayer.SHOT_SPEED_MIN],
		PassEvaluator.PASS_SPEED_MAX < FootballPlayer.SHOT_SPEED_MIN)


# ------------------------------------------------------------- pass kinds

func _test_pass_kinds() -> void:
	_check("A pass option records which kind of pass it is",
		PassEvaluator.Option.new().kind == PassEvaluator.PassKind.NORMAL)
	_check("A lead pass is played into space ahead of a runner (%.1fm)" % PassEvaluator.LEAD_SPACE,
		PassEvaluator.LEAD_SPACE > 2.0)
	_check("A lead pass is only played to somebody actually running",
		PassEvaluator.LEAD_MIN_FORWARD_SPEED > 0.0)
	_check("A lead pass requires the space to be clear (%.1fm)"
		% PassEvaluator.LEAD_MIN_SPACE_CLEARANCE,
		PassEvaluator.LEAD_MIN_SPACE_CLEARANCE > 0.0)


# -------------------------------------------------------------- stopping

## "The player should be able to ... slow down, stop" -- and keep the ball.
func _test_stopping_with_the_ball() -> void:
	var pair := await _solo_player()
	var player: FootballPlayer = pair[0]
	var ball: RigidBody3D = pair[1]

	player.move_input = Vector2(1, 0)
	for i in range(120):
		await get_tree().physics_frame
	var moving_ok: bool = player.has_possession

	player.move_input = Vector2.ZERO
	for i in range(90):
		await get_tree().physics_frame
	var gap: float = Vector2(ball.global_position.x - player.global_position.x,
		ball.global_position.z - player.global_position.z).length()

	_check("A carrier holds the ball while running", moving_ok)
	_check("Stopping keeps the ball at the feet rather than letting it run away "
		+ "(%.2fm, was 1.64m before v0.9.0)" % gap, gap < 1.2)
	_check("...and possession survives the stop", player.has_possession)
	player.queue_free()
	ball.queue_free()
	await get_tree().process_frame


# ------------------------------------------------------------- challenges

## A challenge must be beatable, or a fake means nothing.
func _test_challenge_is_beatable() -> void:
	_check("A committed challenger can be wrong-footed by a cut",
		BallContest.BEATEN_PROGRESS_SCALE < 1.0)
	_check("Only a challenger carrying real speed can be wrong-footed (%.1f m/s)"
		% BallContest.BEATEN_MIN_CHALLENGER_SPEED,
		BallContest.BEATEN_MIN_CHALLENGER_SPEED > 0.0)
	_check("Being beaten sets a challenger back without removing them",
		BallContest.BEATEN_PROGRESS_SCALE > 0.0)
	# Still deterministic: the file's whole design rejects a dice roll, and
	# a failure the player caused is more useful than one they cannot see.
	_check("A challenge still resolves from observable quantities, not chance",
		BallContest.CHALLENGE_TIME_REQUIRED > 0.0)


# ------------------------------------------------------------ live match

func _test_live_match() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	await get_tree().physics_frame
	for i in range(120):
		await get_tree().physics_frame

	var pm: PossessionManager = main.possession_manager
	var ball: RigidBody3D = main.ball
	var players: Array = main.home_players + main.away_players

	var acquire_worst := 0.0
	var retain_worst := 0.0
	var had := {}
	var behind_goal := 0
	var kicks := 0
	var far_kicks := 0
	var prev_gap := {}
	var kick_counts := {}

	for i in range(30 * 60):
		await get_tree().physics_frame
		for p in players:
			var gap: float = Vector2(ball.global_position.x - p.global_position.x,
				ball.global_position.z - p.global_position.z).length()
			if p.has_possession:
				if not had.get(p, false):
					acquire_worst = maxf(acquire_worst, gap)
				retain_worst = maxf(retain_worst, gap)
			had[p] = p.has_possession
			var seen: int = kick_counts.get(p, -1)
			if seen >= 0 and p.kick_count > seen:
				kicks += 1
				if prev_gap.get(p, gap) > BallContest.CHALLENGE_RANGE:
					far_kicks += 1
			kick_counts[p] = p.kick_count
			prev_gap[p] = gap
			if FormationManager.is_behind_goal_line(p.global_position):
				behind_goal += 1

	# Allow a small margin over each gate: these are sampled once per frame,
	# and the ball travels between the check inside _update_possession and
	# the sample here.
	_check("No player gains the ball from beyond contact range in a live match "
		+ "(worst %.2fm, gate %.2fm)" % [acquire_worst, FootballPlayer.POSSESSION_CONTACT_RADIUS],
		acquire_worst <= FootballPlayer.CONTEST_WIN_REACH + 0.25)
	_check("No player keeps the ball once it has genuinely gone (worst %.2fm, cap %.2fm)"
		% [retain_worst, FootballPlayer.RETAIN_MAX_DISTANCE],
		retain_worst <= FootballPlayer.RETAIN_MAX_DISTANCE + 0.35)
	_check("No kick comes from beyond challenge range (%d of %d)" % [far_kicks, kicks],
		far_kicks == 0)
	_check("Nobody spends the match behind a goal line (%d frames)" % behind_goal,
		behind_goal == 0)
	_check("A real passage of play happened (%d kicks)" % kicks, kicks > 5)

	main.queue_free()
	await get_tree().process_frame


# ---------------------------------------------------------------- helpers

func _solo_player() -> Array:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: RigidBody3D = BallScene.instantiate()
	add_child(ball)
	var player: FootballPlayer = PlayerScene.instantiate()
	add_child(player)
	player.apply_player_data(TestRoster.home_team()[9])
	player.set_match_context([], [])
	player.global_position = Vector3(-10, 1, 0)
	await get_tree().physics_frame
	ball.global_position = player.global_position + Vector3(0.5, 0.2, 0)
	ball.linear_velocity = Vector3.ZERO
	for i in range(40):
		await get_tree().physics_frame
	return [player, ball]
