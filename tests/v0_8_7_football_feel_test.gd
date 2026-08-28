extends Node3D

# V0.8.7 regression suite -- dribbling, passing lanes and off-ball support.
#
# Covers the twenty behaviours the milestone brief lists, plus the specific
# defects this milestone root-caused, so a later change that reintroduces
# any of them fails here rather than in a playtest:
#
#   * the dribble leash sitting inside the player's own collision capsule
#     (the ball could never be in front of the dribbler at all)
#   * the close-control sensor being narrower than the leash (a carrier
#     knocked the ball out of their own possession radius)
#   * pass weight being solved from a lead point rather than the receiver
#     (a 9m pass struck at 4.3 m/s, dying 3m short)
#   * a lead unbounded relative to the pass it was refining
#   * support duties choosing positions with no notion of a passing lane
#
# Scenes are shared between related checks: instantiating Main is by far
# the most expensive thing here, and the assertions are a few frames each.

const MainScene := preload("res://scenes/Main.tscn")
const PlayerScene := preload("res://scenes/FootballPlayer.tscn")
const BallScene := preload("res://scenes/Ball.tscn")

var ok := true
## Per-player kick_count watermarks, so a kick is counted once as an event
## rather than every frame its last_kick_kind is still set.
var _kick_counts := {}


func _ready() -> void:
	await _test_ball_and_control_geometry()
	await _test_human_aimed_pass()
	await _test_dribbling()
	await _test_lane_aware_support()
	await _test_live_match_off_ball()
	await _test_preserved_systems()
	print("TEST_SUMMARY: %s" % ("ALL PASS" if ok else "FAILURES PRESENT"))
	get_tree().quit(0 if ok else 1)


func _check(label: String, condition: bool) -> void:
	if condition:
		print("[PASS] %s" % label)
	else:
		ok = false
		print("[FAIL] %s" % label)


# ------------------------------------------------ geometry invariants

## These are pure arithmetic over the scene files, and they are the guard
## rail for the whole milestone: every dribbling symptom in v0.8.6 traced
## back to these three numbers being in the wrong order.
func _test_ball_and_control_geometry() -> void:
	var player: FootballPlayer = PlayerScene.instantiate()
	var ball: RigidBody3D = BallScene.instantiate()
	add_child(player)
	add_child(ball)
	await get_tree().physics_frame

	var capsule: CapsuleShape3D = player.get_node("CollisionShape3D").shape
	var sphere: SphereShape3D = ball.get_node("CollisionShape3D").shape
	var contact_floor: float = capsule.radius + sphere.radius

	_check("The ball is a plausible size next to a player (%.2fm across vs a %.1fm player)"
		% [sphere.radius * 2.0, capsule.height], sphere.radius * 2.0 < capsule.height * 0.30)
	_check("Close control at a walk targets the ball OUTSIDE the player's own capsule (%.2f > %.2f)"
		% [player.dribble_distance, contact_floor], player.dribble_distance > contact_floor)
	_check("...and so does close control at a sprint (%.2f > %.2f)"
		% [player.dribble_distance_sprint, contact_floor], player.dribble_distance_sprint > contact_floor)
	_check("A sprint leash is looser than a walking one",
		player.dribble_distance_sprint > player.dribble_distance)

	# The sensor that decides "am I still in possession" has to contain the
	# leash, or a carrier dispossesses themselves with their own touch.
	var data := PlayerData.new()
	data.defensive_ability = 0.0
	player.apply_player_data(data)
	var control_radius: float = (player.control_area.get_node("CollisionShape3D").shape as SphereShape3D).radius
	_check("The close-control sensor contains the sprint leash even for the least defensive player (%.2f > %.2f)"
		% [control_radius, player.dribble_distance_sprint], control_radius > player.dribble_distance_sprint)

	# 9. the ball is still a simulated body, not something parented.
	_check("The ball is still a freely simulated RigidBody3D", ball is RigidBody3D)
	_check("...that is not attached to any player", ball.get_parent() != player)
	_check("...and still has mass and damping rather than scripted motion",
		ball.mass > 0.0 and ball.linear_damp > 0.0)

	player.queue_free()
	ball.queue_free()
	await get_tree().process_frame


# ------------------------------------------------------ 1, 2, 3: passing

func _test_human_aimed_pass() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(90):
		await get_tree().physics_frame

	var human: FootballPlayer = main.player_controller.controlled_player
	var plan: TeamPlan = main.home_team.plan
	var fwd: Vector3 = plan.forward_axis()
	for p in main.away_players:
		p.global_position = Vector3(-200, 1, 200)
	var mates: Array = []
	for p in main.home_players:
		if p != human and not p.is_goalkeeper:
			mates.append(p)
		if p != human:
			p.global_position = Vector3(200, 1, -200)
	human.global_position = Vector3(0, 1, 0)

	# --- 1. the pass goes where the player aimed, not to whoever is nearest
	# Near teammate off to one side, far teammate straight ahead. Aiming
	# forward must pick the far one: "do NOT always select the closest".
	var near_mate: FootballPlayer = mates[0]
	var far_mate: FootballPlayer = mates[1]
	var side: Vector3 = fwd.rotated(Vector3.UP, deg_to_rad(90.0))
	near_mate.global_position = human.global_position + side * 4.5
	far_mate.global_position = human.global_position + fwd * 11.0
	await get_tree().physics_frame
	await get_tree().physics_frame

	var forward_pick: PassEvaluator.Option = PassEvaluator.best_option(
		human, fwd, fwd, plan, FootballPlayer.PASS_ASSIST_MIN_ALIGNMENT, true)
	_check("Aiming forward selects the teammate aimed at, not the nearer one to the side",
		forward_pick != null and forward_pick.target == far_mate)

	var side_pick: PassEvaluator.Option = PassEvaluator.best_option(
		human, side, fwd, plan, FootballPlayer.PASS_ASSIST_MIN_ALIGNMENT, true)
	_check("Aiming sideways instead selects the sideways teammate",
		side_pick != null and side_pick.target == near_mate)
	_check("The player can therefore choose between two teammates by aim alone",
		forward_pick != null and side_pick != null and forward_pick.target != side_pick.target)

	# --- 2. the pass is weighted to actually REACH the receiver
	# The v0.8.6 defect: weight was solved from the lead point, so a
	# receiver moving toward the passer collapsed the distance and the ball
	# was struck too softly to arrive.
	var reach_failures := 0
	var checked := 0
	for angle in [0.0, 60.0, 120.0, 180.0, 240.0, 300.0]:
		var dir: Vector3 = fwd.rotated(Vector3.UP, deg_to_rad(angle))
		far_mate.global_position = human.global_position + dir * 9.0
		# A receiver running back toward the passer is the case that broke.
		far_mate.velocity = -dir * 5.0
		near_mate.global_position = Vector3(200, 1, -200)
		await get_tree().physics_frame
		var opt: PassEvaluator.Option = PassEvaluator.best_option(
			human, dir, fwd, plan, FootballPlayer.PASS_ASSIST_MIN_ALIGNMENT, true)
		if opt == null:
			reach_failures += 1
			continue
		checked += 1
		var roll: float = PassEvaluator.ROLL_PER_SPEED * opt.speed - PassEvaluator.ROLL_OFFSET
		if roll < opt.distance:
			reach_failures += 1
	_check("A 9m pass is struck hard enough to reach the receiver from every angle (%d of %d fell short)"
		% [reach_failures, checked], reach_failures == 0)

	# The lead may refine where the ball goes, never dominate it.
	far_mate.global_position = human.global_position + fwd * 9.0
	far_mate.velocity = fwd.rotated(Vector3.UP, deg_to_rad(90.0)) * 6.0
	await get_tree().physics_frame
	var led: PassEvaluator.Option = PassEvaluator.best_option(
		human, fwd, fwd, plan, FootballPlayer.PASS_ASSIST_MIN_ALIGNMENT, true)
	if led != null:
		var lead_dist: float = led.aim_point.distance_to(led.target.global_position)
		_check("A moving receiver is led, but by a bounded amount (%.1fm on a %.1fm pass)"
			% [lead_dist, led.distance], lead_dist <= led.distance * PassEvaluator.MAX_LEAD_FRACTION + 0.01)

	# --- 3. a pass is not a shot, and not a weak tap either
	far_mate.velocity = Vector3.ZERO
	await get_tree().physics_frame
	var ball: RigidBody3D = main.ball
	ball.global_position = human.global_position + fwd * 0.6
	ball.global_position.y = 0.3
	ball.linear_velocity = Vector3.ZERO
	for i in range(20):
		await get_tree().physics_frame
	human.execute_pass(FootballPlayer.PASS_ASSIST_MIN_ALIGNMENT, fwd, plan)
	await get_tree().physics_frame
	var pass_speed: float = ball.linear_velocity.length()
	_check("A pass leaves the boot with real pace (%.1f m/s)" % pass_speed, pass_speed > 3.0)
	_check("...but is clearly weaker than a shot (%.1f < %.1f)" % [pass_speed, FootballPlayer.SHOT_SPEED_MIN],
		pass_speed < FootballPlayer.SHOT_SPEED_MIN)
	_check("The pass/shot speed bands cannot overlap by construction",
		PassEvaluator.PASS_SPEED_MAX < FootballPlayer.SHOT_SPEED_MIN)
	_check("Even a pass with no target found is not a shot",
		FootballPlayer.PASS_NO_TARGET_SPEED < FootballPlayer.SHOT_SPEED_MIN)

	main.queue_free()
	await get_tree().process_frame


# ------------------------------------------------ 8, 9, 10: dribbling

func _test_dribbling() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(90):
		await get_tree().physics_frame

	var human: FootballPlayer = main.player_controller.controlled_player
	var ball: RigidBody3D = main.ball
	for p in main.away_players:
		p.global_position = Vector3(-200, 1, 200)
	for p in main.home_players:
		if p != human:
			p.global_position = Vector3(200, 1, -200)

	# --- 8. a directional dribble: run, then turn, and keep the ball
	InputState.move_vector = Vector2.ZERO
	InputState.sprint_held = false
	human.global_position = Vector3(-20, 0.1, 0)
	human.velocity = Vector3.ZERO
	human.reset_intent()
	for i in range(30):
		await get_tree().physics_frame
	# Place the ball only once the player has settled: doing it first and
	# then waiting let the match's own kickoff handling move the ball again,
	# so the run started with it 2.2m away instead of at the player's feet.
	ball.global_position = human.global_position + Vector3(0.8, 0.25, 0)
	ball.linear_velocity = Vector3.ZERO
	ball.angular_velocity = Vector3.ZERO
	for i in range(10):
		await get_tree().physics_frame
	InputState.move_vector = Vector2(1, 0)
	var touches := 0
	var separations: Array = []
	for i in range(90):
		await get_tree().physics_frame
		if human.touched_ball_this_frame:
			touches += 1
		if human.has_possession:
			separations.append(Vector2(ball.global_position.x - human.global_position.x,
				ball.global_position.z - human.global_position.z).length())
	_check("A dribble is made of discrete touches rather than a continuous pull (%d touches)" % touches,
		touches >= 2)
	_check("The ball keeps a real separation from the dribbler rather than sitting on them",
		separations.size() > 30)
	if separations.size() > 0:
		var mean := 0.0
		for s in separations:
			mean += s
		mean /= separations.size()
		var capsule_r := 0.4
		var ball_r := 0.16
		_check("Mean ball separation while running is clear of the player's body (%.2fm > %.2fm)"
			% [mean, capsule_r + ball_r], mean > capsule_r + ball_r)
		_check("...and still inside close control (%.2fm)" % mean, mean < 3.0)

	# Change direction: the ball must follow the new heading. Measured as
	# the ball's actual displacement over the turn rather than an
	# instantaneous velocity sample, which can catch the ball at the moment
	# it is momentarily at rest between touches and read as "no change".
	# A hard turn at pace deliberately costs control for control_loss_duration
	# (the heavy-touch window), during which no touch is applied at all and
	# the ball rightly runs on in the old direction. Measure the ball's
	# heading AFTER that window has expired -- sampling across it just
	# measures the momentum the turn was supposed to cost.
	var before_dir := Vector3(1, 0, 0)
	InputState.move_vector = Vector2(0, 1)
	var kept := 0
	for i in range(45):
		await get_tree().physics_frame
		if human.has_possession:
			kept += 1
	var turn_start: Vector3 = ball.global_position
	for i in range(45):
		await get_tree().physics_frame
		if human.has_possession:
			kept += 1
	var travelled: Vector3 = ball.global_position - turn_start
	travelled.y = 0.0
	var turn_angle: float = before_dir.angle_to(travelled.normalized()) if travelled.length() > 0.4 else 0.0
	_check("A change of direction is followed by the ball (it then travelled %.1fm, %.0f degrees off the old heading)"
		% [travelled.length(), rad_to_deg(turn_angle)], turn_angle > 0.5)
	_check("The dribbler usually keeps the ball through a 90-degree turn (%d/90 frames)" % kept, kept > 35)

	# --- 9. still simulated: the ball responds to an external shove
	var pre: Vector3 = ball.global_position
	ball.apply_central_impulse(Vector3(0, 0, 4.0))
	for i in range(10):
		await get_tree().physics_frame
	_check("An external impulse still moves the ball (it is not pinned to the player)",
		ball.global_position.distance_to(pre) > 0.3)
	InputState.move_vector = Vector2.ZERO

	# A stationary player does not knock the ball away (the phantom-touch bug)
	# Mid-pitch, away from either goal: at x=-20 the loose ball from the
	# impulse check above could roll in for a goal, and the resulting
	# kickoff reset teleports players and re-launches the ball, which reads
	# here as the stationary player having kicked it.
	InputState.move_vector = Vector2.ZERO
	InputState.sprint_held = false
	human.global_position = Vector3(0, 0.1, 0)
	human.velocity = Vector3.ZERO
	human.reset_intent()
	for i in range(20):
		await get_tree().physics_frame
	# Rest the ball ON the ground and measure HORIZONTAL speed only. Dropping
	# it from 0.19m up and reading linear_velocity.length() measured its free
	# fall -- a clean 0.16 m/s per frame of gravity -- not a kick.
	var rest_y: float = (ball.get_node("CollisionShape3D").shape as SphereShape3D).radius
	ball.global_position = Vector3(human.global_position.x, rest_y, human.global_position.z - 0.8)
	ball.linear_velocity = Vector3.ZERO
	ball.angular_velocity = Vector3.ZERO
	var moved := 0.0
	for i in range(40):
		await get_tree().physics_frame
		moved = maxf(moved, Vector2(ball.linear_velocity.x, ball.linear_velocity.z).length())
	_check("A player standing still does not kick the ball away (%.2f m/s)" % moved, moved < 1.0)

	main.queue_free()
	await get_tree().process_frame


# ------------------------------------------- 4: lane-aware positioning

## Direct test of the mechanism, in a arranged situation rather than a
## noisy live match: a supporting player whose duty target is screened by
## an opponent should be moved to a spot the carrier can actually reach.
func _test_lane_aware_support() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(90):
		await get_tree().physics_frame

	var plan: TeamPlan = main.home_team.plan
	var fwd: Vector3 = plan.forward_axis()
	var carrier: FootballPlayer = null
	var supporter: FootballPlayer = null
	for p in main.home_players:
		if p.is_goalkeeper:
			continue
		if carrier == null:
			carrier = p
		elif supporter == null:
			supporter = p
		else:
			p.global_position = Vector3(200, 1, -200)
	for p in main.away_players:
		p.global_position = Vector3(-200, 1, 200)

	carrier.global_position = Vector3(0, 1, 0)
	var base_target: Vector3 = carrier.global_position + fwd * 9.0
	base_target.y = 1.0

	# Plant an opponent exactly on the line between carrier and target.
	var screen: FootballPlayer = main.away_players[1]
	screen.global_position = carrier.global_position + fwd * 4.5
	await get_tree().physics_frame
	# Set the carrier AFTER the last physics frame: TeamPlan recomputes
	# plan.carrier every tick from who actually holds the ball, so assigning
	# it before an await simply had it overwritten with null (nobody is on
	# the ball in this arranged scene) and the refinement returned early.
	plan.carrier = carrier

	var blocked_before: bool = PassEvaluator._lane_blocked(
		carrier.global_position, fwd, 9.0, carrier.opponents)
	_check("The arranged support position really is screened by an opponent", blocked_before)

	var refined: Vector3 = AIController._lane_aware_target(
		supporter, base_target, plan, carrier.opponents, carrier.teammates,
		FormationManager.get_world_position(Vector2(1, 0), 0))
	var to_refined: Vector3 = refined - carrier.global_position
	to_refined.y = 0.0
	var blocked_after: bool = PassEvaluator._lane_blocked(
		carrier.global_position, to_refined.normalized(), to_refined.length(), carrier.opponents)
	_check("Lane-aware support moves off the screened spot to open a passing lane", not blocked_after)
	_check("...without abandoning the tactical position it was given (%.1fm)"
		% refined.distance_to(base_target), refined.distance_to(base_target) <= AIController.LANE_SAMPLE_RADIUS + 0.01)

	# With no screen, the duty's own geometry should be left alone.
	screen.global_position = Vector3(-200, 1, 200)
	await get_tree().physics_frame
	plan.carrier = carrier
	var clear_target: Vector3 = AIController._lane_aware_target(
		supporter, base_target, plan, carrier.opponents, carrier.teammates,
		FormationManager.get_world_position(Vector2(1, 0), 0))
	_check("An already-clear support position is left where the duty put it",
		clear_target.distance_to(base_target) < 0.01)

	main.queue_free()
	await get_tree().process_frame


# --------------------------------- 5, 6, 7, 11, 13, 14: live match

func _test_live_match_off_ball() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	main.home_team.set_human_player(null)
	main.player_controller.set_controlled_player(null)
	for i in range(120):
		await get_tree().physics_frame

	var pm: PossessionManager = main.possession_manager
	var plan: TeamPlan = main.home_team.plan

	var carrier_frames := 0
	var converge_frames := 0
	var lane_open_sum := 0.0
	var lane_total_sum := 0.0
	var mid_far_frames := 0
	var mid_far_moving := 0
	var fwd_ahead_frames := 0
	var fwd_frames := 0
	var ai_passes := 0
	var ai_shots := 0
	var intent_sign_changes := 0
	var prev_sign := 0
	var min_pair_spread := 999.0
	var overlap_frames := 0
	var overlap_samples := 0

	for i in range(int(35.0 * 60.0)):
		await get_tree().physics_frame

		var sign_now: int = signi(int(round(plan.attack_intent)))
		if sign_now != 0 and prev_sign != 0 and sign_now != prev_sign:
			intent_sign_changes += 1
		if sign_now != 0:
			prev_sign = sign_now

		# Kicks are counted by watching kick_count tick over, which is the
		# only per-event signal -- last_kick_kind alone persists after the
		# kick and would be recounted every frame.
		for p in main.home_players:
			var seen: int = _kick_counts.get(p, -1)
			if seen >= 0 and p.kick_count > seen:
				if p.last_kick_kind == FootballPlayer.KickKind.PASS:
					ai_passes += 1
				elif p.last_kick_kind == FootballPlayer.KickKind.SHOT:
					ai_shots += 1
			_kick_counts[p] = p.kick_count

		var carrier: FootballPlayer = pm.current_carrier
		if carrier != null and is_instance_valid(carrier) and carrier in main.home_players:
			carrier_frames += 1
			# 5. teammates must not all pile onto the ball
			var near_ball := 0
			for mate in main.home_players:
				if mate == carrier or mate.is_goalkeeper:
					continue
				if mate.global_position.distance_to(main.ball.global_position) < 6.0:
					near_ball += 1
			if near_ball >= 4:
				converge_frames += 1
			# 4. how many in-range teammates are actually passable
			for mate in main.home_players:
				if mate == carrier or mate.is_goalkeeper:
					continue
				var to_mate: Vector3 = mate.global_position - carrier.global_position
				to_mate.y = 0.0
				var d: float = to_mate.length()
				if d < PassEvaluator.MIN_PASS_DISTANCE or d > PassEvaluator.MAX_PASS_DISTANCE:
					continue
				lane_total_sum += 1.0
				if not PassEvaluator._lane_blocked(carrier.global_position, to_mate / d, d, carrier.opponents):
					lane_open_sum += 1.0
			# 6. forwards should get beyond the ball, not behind it
			for p in main.home_players:
				if FormationManager.role_category(p.formation_role) != "FWD":
					continue
				fwd_frames += 1
				var fwd_axis: Vector3 = plan.forward_axis()
				if (p.global_position - main.ball.global_position).dot(fwd_axis) > 0.0:
					fwd_ahead_frames += 1

		# 7. midfielders far from the ball still adjusting
		for p in main.home_players:
			if p.is_goalkeeper or FormationManager.role_category(p.formation_role) != "MID":
				continue
			if p.global_position.distance_to(main.ball.global_position) > 20.0:
				mid_far_frames += 1
				if p.velocity.length() > 0.5:
					mid_far_moving += 1

		# Spacing, measured as how OFTEN two outfielders are on top of each
		# other rather than the single closest instant ever seen. A kickoff
		# or post-goal reset teleports the whole side onto formation slots
		# and can momentarily overlap two capsules; that is a spawn artifact,
		# not the bunching the brief is asking about.
		if i % 30 == 0:
			overlap_samples += 1
			var closest := 999.0
			for a in main.home_players:
				if a.is_goalkeeper:
					continue
				for b in main.home_players:
					if b == a or b.is_goalkeeper:
						continue
					closest = minf(closest, a.global_position.distance_to(b.global_position))
			min_pair_spread = minf(min_pair_spread, closest)
			# 1.0m is roughly two capsules touching (0.4 + 0.4). Anything
			# above that is normal team shape at 10 outfielders a side, not
			# the bunching the brief is about.
			if closest < 1.0:
				overlap_frames += 1

	_check("Sampled a real passage of AI play (%d carrier frames)" % carrier_frames, carrier_frames > 100)
	if carrier_frames > 0:
		var converge_pct: float = 100.0 * converge_frames / carrier_frames
		_check("Teammates do not all converge on the ball (%.0f%% of frames had 4+ within 6m)" % converge_pct,
			converge_pct < 50.0)
	if lane_total_sum > 0:
		var open_pct: float = 100.0 * lane_open_sum / lane_total_sum
		_check("A useful share of in-range teammates have a clear passing lane (%.0f%%)" % open_pct,
			open_pct > 50.0)
	if fwd_frames > 0:
		var ahead_pct: float = 100.0 * fwd_ahead_frames / fwd_frames
		_check("Forwards get beyond the ball while their team attacks (%.0f%% of the time)" % ahead_pct,
			ahead_pct > 30.0)
	if mid_far_frames > 0:
		var moving_pct: float = 100.0 * mid_far_moving / mid_far_frames
		_check("Midfielders keep adjusting when the ball is far away (%.0f%% moving)" % moving_pct,
			moving_pct > 20.0)
	if overlap_samples > 0:
		var overlap_pct: float = 100.0 * overlap_frames / overlap_samples
		_check("Outfield teammates are not bunched on top of each other (%.0f%% of samples, closest ever %.2fm)"
			% [overlap_pct, min_pair_spread], overlap_pct < 20.0)
	_check("AI teammates still pass to each other (%d passes in 35s)" % ai_passes, ai_passes > 3)
	_check("Tactical phase stays stable rather than flapping (%d sign changes in 35s)" % intent_sign_changes,
		intent_sign_changes < 40)

	main.queue_free()
	await get_tree().process_frame


# ------------------ 12, 15, 16, 17, 18, 19: preserved systems

func _test_preserved_systems() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(90):
		await get_tree().physics_frame

	var human: FootballPlayer = main.player_controller.controlled_player
	var plan: TeamPlan = main.home_team.plan
	var fwd: Vector3 = plan.forward_axis()

	# --- 12. the human is still a legitimate AI pass target
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
	var option: PassEvaluator.Option = PassEvaluator.best_option(
		carrier, fwd, fwd, plan, FootballPlayer.PASS_SEARCH_MIN_ALIGNMENT_OMNI)
	_check("The human is still evaluated as an AI pass option", option != null)
	_check("...and still selected when they are the best one", option != null and option.target == human)

	# --- 19. nobody can be sent behind the goal line
	var beyond := Vector3(FormationManager.GOAL_LINE_X + 8.0, 1.0, 0.0)
	var clamped: Vector3 = FormationManager.clamp_to_playable(beyond)
	_check("Targets beyond the goal line are clamped back into play",
		not FormationManager.is_behind_goal_line(clamped))
	_check("A lane-aware support target never lands behind the goal line",
		not FormationManager.is_behind_goal_line(AIController._lane_aware_target(
			carrier, beyond, plan, carrier.opponents, carrier.teammates,
			FormationManager.get_world_position(Vector2(1, 0), 0))))

	# --- 15. goalkeeper untouched
	var keeper: FootballPlayer = main.home_players[0]
	_check("The home goalkeeper is still flagged as one", keeper.is_goalkeeper)
	var own_goal: Vector3 = FormationManager.get_world_position(Vector2(-1, 0), 0)
	var furthest := 0.0
	var biggest_step := 0.0
	var previous: Vector3 = keeper.global_position
	for i in range(240):
		await get_tree().physics_frame
		furthest = maxf(furthest, keeper.global_position.distance_to(own_goal))
		biggest_step = maxf(biggest_step, previous.distance_to(keeper.global_position))
		previous = keeper.global_position
	_check("The goalkeeper still holds its own area (max %.1fm from goal)" % furthest, furthest < 12.0)
	_check("The goalkeeper still moves smoothly (max step %.2fm)" % biggest_step, biggest_step < 0.5)
	_check("The goalkeeper is never given an outfield attacking duty",
		plan.duty_of(keeper) == TeamPlan.Duty.COVER_SPACE)

	# --- 18. team identification
	var home_ring: MeshInstance3D = main.home_players[3].team_ring
	var away_ring: MeshInstance3D = main.away_players[3].team_ring
	_check("Every player carries a team marker", home_ring != null and away_ring != null)
	_check("Team markers are visible in normal play", home_ring.visible and away_ring.visible)
	var home_mat: StandardMaterial3D = home_ring.get_surface_override_material(0)
	var away_mat: StandardMaterial3D = away_ring.get_surface_override_material(0)
	if home_mat != null and away_mat != null:
		var separation: float = Vector3(
			home_mat.albedo_color.r - away_mat.albedo_color.r,
			home_mat.albedo_color.g - away_mat.albedo_color.g,
			home_mat.albedo_color.b - away_mat.albedo_color.b).length()
		_check("Teams are told apart by marker colour (separation %.2f)" % separation, separation > 0.4)

	# --- 16. multitouch
	var before: FootballPlayer = main.player_controller.controlled_player
	InputState.move_vector = Vector2(0.6, -0.4)
	InputState.sprint_held = true
	InputState.shoot_held = true
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check("Joystick input still reaches the controlled player", before.move_input.length() > 0.5)
	_check("Sprint input still reaches the controlled player", before.sprint_requested)
	_check("Shoot-hold still reaches the controlled player", before.shoot_held)
	InputState.move_vector = Vector2.ZERO
	InputState.sprint_held = false
	InputState.shoot_held = false
	await get_tree().physics_frame

	# --- 17. player switching
	var old: FootballPlayer = main.player_controller.controlled_player
	InputState.switch_pressed = true
	for i in range(4):
		await get_tree().physics_frame
	var now: FootballPlayer = main.player_controller.controlled_player
	_check("Player switching still changes the controlled player", now != old)
	_check("Switching still lands on a home-roster player", now in main.home_players)

	# --- 13. AI shooting still works. Arranged rather than hoped for: a
	# 35-second match can legitimately never produce a clear sight of goal,
	# so waiting for one is a flaky way to assert the mechanism exists.
	# Hand the whole home side to the AI first: by this point the switching
	# check above has moved human control to some other player, and a
	# human-controlled shooter is never driven by AIController at all.
	main.home_team.set_human_player(null)
	main.player_controller.set_controlled_player(null)
	await get_tree().physics_frame
	var shooter: FootballPlayer = null
	for p in main.home_players:
		if not p.is_goalkeeper:
			shooter = p
			break
	var target_goal: Vector3 = FormationManager.attacking_goal_mouth(fwd)
	# Everyone parked here is restored afterwards -- the goalkeeper checks
	# below run on this same scene, and leaving the keeper 200m away made
	# them fail with a nonsense 301m-from-goal reading.
	var parked := {}
	for p in main.home_players:
		if p != shooter:
			parked[p] = p.global_position
			p.global_position = Vector3(200, 1, -200)
	for p in main.away_players:
		parked[p] = p.global_position
		p.global_position = Vector3(-200, 1, 200)
	shooter.global_position = target_goal - fwd * 9.0
	shooter.global_position.y = 0.1
	shooter.reset_intent()
	var shot_ball: RigidBody3D = main.ball
	# Settle the shooter first, then give them the ball: placing the ball in
	# the same frame let the match's own ball handling move it, and the
	# shooter jogged off goalwards without ever gaining possession.
	for i in range(20):
		await get_tree().physics_frame
	shot_ball.global_position = shooter.global_position + fwd * 0.5
	shot_ball.global_position.y = (shot_ball.get_node("CollisionShape3D").shape as SphereShape3D).radius
	shot_ball.linear_velocity = Vector3.ZERO
	shot_ball.angular_velocity = Vector3.ZERO
	for i in range(10):
		await get_tree().physics_frame
	var shot_seen := false
	var shot_speed := 0.0
	for i in range(240):
		await get_tree().physics_frame
		if shooter.last_kick_kind == FootballPlayer.KickKind.SHOT:
			shot_seen = true
			shot_speed = maxf(shot_speed, shot_ball.linear_velocity.length())
			break
	_check("An AI in sight of goal still shoots", shot_seen)
	if shot_seen:
		await get_tree().physics_frame
		_check("...and the shot is struck at shot pace, not pass pace (%.1f m/s)" % shot_speed,
			shot_speed >= PassEvaluator.PASS_SPEED_MAX)
	for p in parked.keys():
		if is_instance_valid(p):
			p.global_position = parked[p]
	for i in range(30):
		await get_tree().physics_frame


	main.queue_free()
	await get_tree().process_frame
