extends Node3D

# V0.8.8 regression suite -- possession validity, directional passing, and
# the systems this milestone had to leave standing.
#
# The defects this milestone root-caused, each of which is asserted below so
# a later change cannot quietly reintroduce it:
#
#  * execute_pass/execute_shot required only a ball inside the 2.5m
#    ActionArea and asked nothing about possession, so any player could
#    strike a ball somebody else was dribbling (measured: 14% of all kicks
#    were struck by a player who was not the carrier, from up to 2.54m).
#  * has_possession answered "is the ball in my ControlArea", and that
#    radius has to be wide enough to hold the dribble leash -- so simply
#    standing ~1.7m from a dribbled ball won it, with no contact and no
#    challenge (40% of possession changes had no challenge at all).
#  * Every attacking slot count came from the slewed attack_intent, which
#    with frequent turnovers never commits, so nearly half the outfield held
#    defensive shape during their own attack.

const MainScene := preload("res://scenes/Main.tscn")
const FieldScene := preload("res://scenes/Field.tscn")
const BallScene := preload("res://scenes/Ball.tscn")
const PlayerScene := preload("res://scenes/FootballPlayer.tscn")

var ok := true
var _kick_counts := {}


func _ready() -> void:
	await _test_possession_requires_contact()
	await _test_kicks_require_possession()
	await _test_directional_pass()
	await _test_dribbling_and_physics()
	await _test_live_match()
	await _test_preserved_systems()
	print("TEST_SUMMARY: %s" % ("ALL PASS" if ok else "FAILURES PRESENT"))
	get_tree().quit(0 if ok else 1)


func _check(label: String, condition: bool) -> void:
	if condition:
		print("[PASS] %s" % label)
	else:
		ok = false
		print("[FAIL] %s" % label)


func _mk(pos: Vector3, team: int, role: String = "CM") -> FootballPlayer:
	var data := PlayerData.new()
	data.id = role + str(team)
	data.display_name = role
	data.movement_speed = 5.0
	data.acceleration = 14.0
	data.sprint_speed = 8.5
	data.passing = 70
	data.shooting = 70
	data.dribbling = 70
	data.stamina = 80
	data.defensive_ability = 60
	var p: FootballPlayer = PlayerScene.instantiate()
	p.position = pos
	p.team_id = team
	p.formation_role = role
	add_child(p)
	p.apply_player_data(data)
	return p


# ------------------------------------- 1, 4: possession needs contact

func _test_possession_requires_contact() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: RigidBody3D = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var carrier: FootballPlayer = _mk(Vector3(0, 0.1, 0), 0)
	# Stood at the distance the pre-v0.8.8 bug actually handed possession
	# over at: measured in a live match, the dispossessed player was 1.61m
	# from the ball on average. With the ball at the carrier's feet this
	# puts the thief ~1.7m from it -- close enough to look plausible on
	# screen, far too far to have touched it.
	var thief: FootballPlayer = _mk(Vector3(2.2, 0.1, 0), 1)
	var pm := PossessionManager.new()
	add_child(pm)
	pm.setup([carrier, thief], ball)
	carrier.set_possession_manager(pm)
	thief.set_possession_manager(pm)
	carrier.set_match_context([carrier], [thief])
	thief.set_match_context([thief], [carrier])

	# Ball at the carrier's feet; the thief stands 1.6m away -- inside the
	# ControlArea that used to be the whole possession test, but nowhere
	# near the ball.
	var rest_y: float = (ball.get_node("CollisionShape3D").shape as SphereShape3D).radius
	ball.global_position = Vector3(0.5, rest_y, 0)
	ball.linear_velocity = Vector3.ZERO
	for i in range(40):
		await get_tree().physics_frame

	_check("The carrier, with the ball at their feet, has possession", carrier.has_possession)
	var thief_gap: float = thief.global_position.distance_to(ball.global_position)
	_check("The thief is well outside contact range (%.2fm vs a %.2fm contact radius)"
		% [thief_gap, FootballPlayer.POSSESSION_CONTACT_RADIUS],
		thief_gap > FootballPlayer.POSSESSION_CONTACT_RADIUS + 0.1)
	_check("...and therefore cannot simply be handed possession from there", not thief.has_possession)
	_check("...and is not elected carrier over the player actually on the ball",
		pm.current_carrier == carrier)

	# 4. A stationary opponent at a genuinely unreachable distance never
	#    takes the ball.
	#
	#    Deliberately measured from the BALL, not from the carrier. The
	#    first version of this check stood the thief 1.6m from the carrier
	#    and called that unreachable -- but the ball sits between them, so
	#    they were 1.11m from it, well inside BallContest's 2.4m challenge
	#    range. They built a challenge and won the ball, which is exactly
	#    what a defender that close SHOULD be able to do; the test was
	#    wrong, not the game. "Clearly unreachable" has to mean outside
	#    challenge range altogether.
	thief.global_position = Vector3(5.0, 0.1, 0)
	for i in range(20):
		await get_tree().physics_frame
	var far_gap: float = thief.global_position.distance_to(ball.global_position)
	_check("The distant opponent is outside challenge range entirely (%.2fm vs %.2fm)"
		% [far_gap, BallContest.CHALLENGE_RANGE], far_gap > BallContest.CHALLENGE_RANGE)
	var stolen := false
	for i in range(180):
		await get_tree().physics_frame
		if pm.current_carrier == thief:
			stolen = true
	_check("1/4. A player at an unreachable distance never steals a ball under control", not stolen)

	# But a challenger who genuinely gets to the ball still wins it -- the
	# brief requires stealing to survive this fix.
	# Positioned relative to where the ball actually IS now, not to where it
	# was placed at the start of this scene -- it has had several seconds to
	# settle and drift since.
	thief.global_position = ball.global_position + Vector3(0.45, 0.0, 0.3)
	thief.global_position.y = 0.1
	var won := false
	for i in range(300):
		await get_tree().physics_frame
		if pm.current_carrier == thief:
			won = true
			break
	_check("A challenger who actually reaches the ball can still win it", won)

	carrier.queue_free()
	thief.queue_free()
	ball.queue_free()
	pm.queue_free()
	field.queue_free()
	await get_tree().process_frame


# ------------------------------------------- 2, 3: kicks need possession

func _test_kicks_require_possession() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: RigidBody3D = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var kicker: FootballPlayer = _mk(Vector3(0, 0.1, 0), 0)
	var mate: FootballPlayer = _mk(Vector3(8, 0.1, 0), 0)
	kicker.set_match_context([kicker, mate], [])
	var rest_y: float = (ball.get_node("CollisionShape3D").shape as SphereShape3D).radius

	# Ball 2.0m away: inside the 2.5m ActionArea, outside any believable
	# contact. This is exactly the case that used to be kickable.
	ball.global_position = Vector3(2.0, rest_y, 0)
	ball.linear_velocity = Vector3.ZERO
	for i in range(30):
		await get_tree().physics_frame
	_check("The ball at 2.0m is inside the action sensor (the old licence to kick)",
		kicker.ball_in_action_range != null)
	_check("...but the player does not have possession of it", not kicker.has_possession)

	var before_speed: float = ball.linear_velocity.length()
	var before_kicks: int = kicker.kick_count
	kicker.execute_pass()
	kicker.execute_shot(1.0)
	await get_tree().physics_frame
	_check("2. A player without possession cannot PASS the ball", kicker.kick_count == before_kicks)
	_check("3. A player without possession cannot SHOOT the ball",
		ball.linear_velocity.length() <= before_speed + 0.5)

	# With the ball genuinely at their feet, both work again.
	ball.global_position = Vector3(0.5, rest_y, 0)
	ball.linear_velocity = Vector3.ZERO
	for i in range(30):
		await get_tree().physics_frame
	_check("With the ball at their feet the player does have possession", kicker.has_possession)
	kicker.execute_pass(FootballPlayer.PASS_ASSIST_MIN_ALIGNMENT, Vector3(1, 0, 0))
	await get_tree().physics_frame
	_check("...and CAN pass (%d kicks)" % kicker.kick_count, kicker.kick_count > before_kicks)
	_check("...recorded as a PASS", kicker.last_kick_kind == FootballPlayer.KickKind.PASS)

	kicker.queue_free()
	mate.queue_free()
	ball.queue_free()
	field.queue_free()
	await get_tree().process_frame


# ------------------------------------------- 5, 6, 7: directional pass

func _test_directional_pass() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(90):
		await get_tree().physics_frame

	var human: FootballPlayer = main.player_controller.controlled_player
	var plan: TeamPlan = main.home_team.plan
	var fwd: Vector3 = plan.forward_axis()
	var mates: Array = []
	for p in main.home_players:
		if p != human and not p.is_goalkeeper:
			mates.append(p)
		if p != human:
			p.global_position = Vector3(200, 1, -200)
	for p in main.away_players:
		p.global_position = Vector3(-200, 1, 200)
	human.global_position = Vector3(0, 1, 0)

	var near_mate: FootballPlayer = mates[0]
	var far_mate: FootballPlayer = mates[1]

	# The brief's own example: a 3m teammate off to the side, an 8m one
	# straight down the aim. Direction must win.
	var wrong := 0
	var nothing := 0
	for angle in [0.0, 45.0, 90.0, 135.0, 180.0, 270.0]:
		var aim: Vector3 = fwd.rotated(Vector3.UP, deg_to_rad(angle))
		var side: Vector3 = aim.rotated(Vector3.UP, deg_to_rad(115.0))
		far_mate.global_position = human.global_position + aim * 8.0
		near_mate.global_position = human.global_position + side * 3.0
		far_mate.velocity = Vector3.ZERO
		near_mate.velocity = Vector3.ZERO
		await get_tree().physics_frame
		await get_tree().physics_frame
		var opt: PassEvaluator.Option = PassEvaluator.best_option(
			human, aim, fwd, plan, FootballPlayer.PASS_ASSIST_MIN_ALIGNMENT, true)
		if opt == null:
			nothing += 1
		elif opt.target != far_mate:
			wrong += 1
	_check("5. PASS follows the stick, not proximity (%d of 6 aims picked the near off-aim teammate, %d found nothing)"
		% [wrong, nothing], wrong == 0 and nothing == 0)

	# 6. It reaches them: the ball must be struck hard enough to cover the
	#    real distance, from every angle.
	var short_of := 0
	for angle in [0.0, 60.0, 120.0, 180.0, 240.0, 300.0]:
		var aim: Vector3 = fwd.rotated(Vector3.UP, deg_to_rad(angle))
		far_mate.global_position = human.global_position + aim * 9.0
		far_mate.velocity = -aim * 5.0
		near_mate.global_position = Vector3(200, 1, -200)
		await get_tree().physics_frame
		var opt: PassEvaluator.Option = PassEvaluator.best_option(
			human, aim, fwd, plan, FootballPlayer.PASS_ASSIST_MIN_ALIGNMENT, true)
		if opt == null:
			short_of += 1
			continue
		if PassEvaluator.ROLL_PER_SPEED * opt.speed - PassEvaluator.ROLL_OFFSET < opt.distance:
			short_of += 1
	_check("6. A 9m pass is weighted to actually reach the receiver (%d of 6 fell short)" % short_of,
		short_of == 0)

	# 7. PASS stays weaker than SHOOT, by construction and in practice.
	_check("7. The pass and shot speed bands cannot overlap",
		PassEvaluator.PASS_SPEED_MAX < FootballPlayer.SHOT_SPEED_MIN)
	_check("...including a pass with no target found",
		FootballPlayer.PASS_NO_TARGET_SPEED < FootballPlayer.SHOT_SPEED_MIN)

	main.queue_free()
	await get_tree().process_frame


# --------------------------------- 14, 15, 16: dribbling and physics

func _test_dribbling_and_physics() -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: RigidBody3D = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var p: FootballPlayer = _mk(Vector3(-20, 0.1, 0), 0)
	var rest_y: float = (ball.get_node("CollisionShape3D").shape as SphereShape3D).radius
	ball.global_position = Vector3(-19.4, rest_y, 0)
	ball.linear_velocity = Vector3.ZERO
	for i in range(30):
		await get_tree().physics_frame
	_check("15. The ball is a freely simulated RigidBody3D with mass and damping",
		ball is RigidBody3D and ball.mass > 0.0 and ball.linear_damp > 0.0)
	_check("...and is not parented to the player", ball.get_parent() != p)

	# 14. Directional dribbling: run, then turn, and the ball follows.
	p.move_input = Vector2(1, 0)
	var touches := 0
	for i in range(70):
		await get_tree().physics_frame
		if p.touched_ball_this_frame:
			touches += 1
	_check("14. A dribble is made of discrete touches (%d)" % touches, touches >= 2)
	var before: Vector3 = ball.global_position
	p.move_input = Vector2(0, 1)
	for i in range(45):
		await get_tree().physics_frame
	var turn_start: Vector3 = ball.global_position
	for i in range(45):
		await get_tree().physics_frame
	var travelled: Vector3 = ball.global_position - turn_start
	travelled.y = 0.0
	var turned: float = Vector3(1, 0, 0).angle_to(travelled.normalized()) if travelled.length() > 0.4 else 0.0
	_check("...and a change of direction is followed by the ball (%.0f degrees off the old heading)"
		% rad_to_deg(turned), turned > 0.5)

	# 16. Still stealable: an external impulse still moves it.
	p.move_input = Vector2.ZERO
	var pre: Vector3 = ball.global_position
	ball.apply_central_impulse(Vector3(0, 0, 4.0))
	for i in range(10):
		await get_tree().physics_frame
	_check("16. The ball still responds to an outside impulse", ball.global_position.distance_to(pre) > 0.3)

	p.queue_free()
	ball.queue_free()
	field.queue_free()
	await get_tree().process_frame


# ------------------ 8, 10, 11, 12, 13, 17, 18, 19: live match

func _test_live_match() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	main.home_team.set_human_player(null)
	main.player_controller.set_controlled_player(null)
	for i in range(120):
		await get_tree().physics_frame

	var pm: PossessionManager = main.possession_manager
	var plan: TeamPlan = main.home_team.plan

	var ai_passes := 0
	var carrier_frames := 0
	var option_sum := 0.0
	var converge_frames := 0
	var mid_far_frames := 0
	var mid_far_moving := 0
	var fwd_ahead := 0
	var fwd_total := 0
	var behind_goal := 0
	var reversals := 0
	var prev_dir := {}
	var phase_flips := 0
	var prev_sign := 0
	var far_kicks := 0
	var kicks := 0
	var worst_kick_gap := 0.0
	# Distance from each player to the ball as of the PREVIOUS physics frame
	# -- see the kick block below for why this test cannot use the current
	# one.
	var prev_gap := {}

	for i in range(int(35.0 * 60.0)):
		await get_tree().physics_frame

		for p in main.home_players + main.away_players:
			var gap: float = p.global_position.distance_to(main.ball.global_position)
			var seen: int = _kick_counts.get(p, -1)
			if seen >= 0 and p.kick_count > seen:
				kicks += 1
				# Measured as of the frame BEFORE the kick landed, which is
				# the only frame on which the question means anything.
				#
				# `kick_count` is incremented inside the player's own
				# _physics_process, the ball is integrated with its new
				# launch velocity later in that same frame, and this loop
				# only resumes after both. So by the time the test can see
				# that a kick happened, the ball has already left -- a shot
				# at ~22 m/s is 0.37m away after a single frame. Measuring
				# the gap here reports where the ball went, not where it was
				# struck from, and it overstates hardest for the hardest
				# kicks. That artifact alone put 1 of 41 legal kicks over
				# the 2.4m line; against the previous frame it is 0 of 41.
				var strike_gap: float = prev_gap.get(p, gap)
				worst_kick_gap = maxf(worst_kick_gap, strike_gap)
				if strike_gap > 2.4:
					far_kicks += 1
				if p in main.home_players and p.last_kick_kind == FootballPlayer.KickKind.PASS:
					ai_passes += 1
			_kick_counts[p] = p.kick_count
			prev_gap[p] = gap
			if FormationManager.is_behind_goal_line(p.global_position):
				behind_goal += 1
			var v := Vector2(p.velocity.x, p.velocity.z)
			if v.length() > 1.0:
				var d: Vector2 = v.normalized()
				if prev_dir.has(p) and d.dot(prev_dir[p]) < -0.7:
					reversals += 1
				prev_dir[p] = d

		var s: int = signi(int(round(plan.attack_intent)))
		if s != 0 and prev_sign != 0 and s != prev_sign:
			phase_flips += 1
		if s != 0:
			prev_sign = s

		for p in main.home_players:
			if p.is_goalkeeper:
				continue
			var cat: String = FormationManager.role_category(p.formation_role)
			if cat == "MID" and p.global_position.distance_to(main.ball.global_position) > 20.0:
				mid_far_frames += 1
				if p.velocity.length() > 0.5:
					mid_far_moving += 1

		var carrier: FootballPlayer = pm.current_carrier
		if carrier == null or not is_instance_valid(carrier) or not (carrier in main.home_players):
			continue
		carrier_frames += 1
		var near := 0
		for mate in main.home_players:
			if mate == carrier or mate.is_goalkeeper:
				continue
			if mate.global_position.distance_to(main.ball.global_position) < 6.0:
				near += 1
			var to_mate: Vector3 = mate.global_position - carrier.global_position
			to_mate.y = 0.0
			var d2: float = to_mate.length()
			if d2 >= PassEvaluator.MIN_PASS_DISTANCE and d2 <= PassEvaluator.MAX_PASS_DISTANCE \
				and not PassEvaluator._lane_blocked(carrier.global_position, to_mate / d2, d2, carrier.opponents):
				option_sum += 1.0
		if near >= 4:
			converge_frames += 1
		for p in main.home_players:
			if FormationManager.role_category(p.formation_role) != "FWD":
				continue
			fwd_total += 1
			if (p.global_position - main.ball.global_position).dot(plan.forward_axis()) > 0.0:
				fwd_ahead += 1

	_check("Sampled a real passage of AI play (%d carrier frames)" % carrier_frames, carrier_frames > 100)
	_check("1/2/3. No kick in a live match comes from beyond challenge range (%d of %d, worst %.2fm)"
		% [far_kicks, kicks, worst_kick_gap], far_kicks == 0)
	_check("8. AI teammates still pass to each other (%d in 35s)" % ai_passes, ai_passes > 3)
	if carrier_frames > 0:
		_check("10. The carrier has real passing options (%.1f clear per frame)" % (option_sum / carrier_frames),
			option_sum / carrier_frames >= 1.0)
		_check("11. Teammates do not all converge on the ball (%.0f%% of frames had 4+ within 6m)"
			% (100.0 * converge_frames / carrier_frames), 100.0 * converge_frames / carrier_frames < 50.0)
	if mid_far_frames > 0:
		_check("12. Midfielders keep adjusting when the ball is far (%.0f%% moving)"
			% (100.0 * mid_far_moving / mid_far_frames), 100.0 * mid_far_moving / mid_far_frames > 20.0)
	if fwd_total > 0:
		_check("13. Forwards get beyond the ball (%.0f%% of the time)" % (100.0 * fwd_ahead / fwd_total),
			100.0 * fwd_ahead / fwd_total > 25.0)
	_check("17. Tactical phase stays stable (%d sign changes in 35s)" % phase_flips, phase_flips < 40)
	_check("18. Movement reversals stay bounded (%.2f per player per second)"
		% (reversals / 35.0 / 22.0), reversals / 35.0 / 22.0 < 0.30)
	_check("19. No player is ever behind a goal line (%d player-frames)" % behind_goal, behind_goal == 0)

	main.queue_free()
	await get_tree().process_frame


# --------------------------- 9, 20, 21, 22: preserved systems

func _test_preserved_systems() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(90):
		await get_tree().physics_frame

	var human: FootballPlayer = main.player_controller.controlled_player
	var plan: TeamPlan = main.home_team.plan
	var fwd: Vector3 = plan.forward_axis()

	# 9. the human remains a legitimate AI pass target
	var carrier: FootballPlayer = null
	for p in main.home_players:
		if p != human and not p.is_goalkeeper:
			carrier = p
			break
	carrier.global_position = Vector3(0, 1, 0)
	human.global_position = carrier.global_position + fwd * 9.0
	for p in main.away_players:
		p.global_position = Vector3(-200, 1, 200)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var opt: PassEvaluator.Option = PassEvaluator.best_option(
		carrier, fwd, fwd, plan, FootballPlayer.PASS_SEARCH_MIN_ALIGNMENT_OMNI)
	_check("9. The human is still selected as an AI pass target when best placed",
		opt != null and opt.target == human)

	# 20. goalkeeper
	var keeper: FootballPlayer = main.home_players[0]
	var own_goal: Vector3 = FormationManager.get_world_position(Vector2(-1, 0), 0)
	var furthest := 0.0
	var biggest_step := 0.0
	var previous: Vector3 = keeper.global_position
	for i in range(240):
		await get_tree().physics_frame
		furthest = maxf(furthest, keeper.global_position.distance_to(own_goal))
		biggest_step = maxf(biggest_step, previous.distance_to(keeper.global_position))
		previous = keeper.global_position
	_check("20. The goalkeeper still holds its area (max %.1fm from goal)" % furthest, furthest < 12.0)
	_check("...and still moves smoothly (max step %.2fm)" % biggest_step, biggest_step < 0.5)
	_check("...and is still flagged as a goalkeeper on a defensive duty",
		keeper.is_goalkeeper and plan.duty_of(keeper) == TeamPlan.Duty.COVER_SPACE)

	# 21. multitouch
	var before: FootballPlayer = main.player_controller.controlled_player
	InputState.move_vector = Vector2(0.6, -0.4)
	InputState.sprint_held = true
	InputState.shoot_held = true
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check("21. Joystick, sprint and shoot all reach the controlled player at once",
		before.move_input.length() > 0.5 and before.sprint_requested and before.shoot_held)
	InputState.move_vector = Vector2.ZERO
	InputState.sprint_held = false
	InputState.shoot_held = false
	await get_tree().physics_frame

	# 22. switching
	var old: FootballPlayer = main.player_controller.controlled_player
	InputState.switch_pressed = true
	for i in range(4):
		await get_tree().physics_frame
	var now: FootballPlayer = main.player_controller.controlled_player
	_check("22. Player switching still changes the controlled player", now != old)
	_check("...and still lands on a home-roster player", now in main.home_players)

	main.queue_free()
	await get_tree().process_frame
