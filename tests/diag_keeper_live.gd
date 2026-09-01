extends Node3D

## Blocker 2: what does the keeper actually DO in a match?
##
## V0_9_1_1GoalkeeperTest is 13/13 and QA still lists goalkeeper intelligence
## as a blocker, so the suite is measuring the wrong thing. A rendered capture
## during the previous milestone showed Home 0 - 7 Away at twelve minutes,
## which is the measurable form of the complaint.
##
## This measures the things a person watching would notice:
##
##   goals conceded, and how long the match ran
##   every shot that ended up on target, and what the keeper was DOING
##   the keeper's intent distribution over the whole match
##   how far off the line the keeper strays
##   where the keeper was, and what they intended, at the moment of each goal
##
## Nothing here changes behaviour. It establishes the baseline first.

const MainScene := preload("res://scenes/Main.tscn")
const SECONDS := 150

## Ball closing on a goal inside this distance counts as a chance worth
## recording, whether or not it goes in.
const CHANCE_RANGE := 16.0

## How far back the rolling snapshot reaches. Half a second: long enough that
## the ball is still in flight toward the goal, short enough to be the same
## passage of play.
const HISTORY_FRAMES := 30


func _ready() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(90):
		await get_tree().physics_frame

	var ball: RigidBody3D = main.ball
	var keepers: Array = []
	for p in (main.home_players + main.away_players):
		if p.is_goalkeeper:
			keepers.append(p)
	print("KEEPER: %d keepers, %ds of match" % [keepers.size(), SECONDS])

	# Did the keeper ever actually commit to a dive, and what came of it? The
	# scoreline alone cannot answer this -- run-to-run variance in this project
	# is large enough to swallow the effect either way.
	var saves := {"CAUGHT": 0, "PARRIED": 0, "MISSED": 0}
	for k in keepers:
		k.save_resolved.connect(func(info):
			var n: String = str(info.get("outcome_name", "NONE"))
			saves[n] = saves.get(n, 0) + 1)

	var intent_frames := {}
	var off_line_sum := 0.0
	var off_line_max := 0.0
	var samples := 0
	var goals: Array = []
	var chances := 0
	var last_home: int = main.home_score
	var last_away: int = main.away_score
	var in_chance := false
	var history: Array = []
	# Closest the conceding keeper's body ever came to the ball during the
	# approach. This is the number that decides whether a realistic dive reach
	# would have changed the outcome -- a keeper who was never within two
	# metres has a positioning problem, one who was within one metre has an
	# execution problem.
	var approach_min := {0: INF, 1: INF}

	for i in range(SECONDS * 60):
		await get_tree().physics_frame
		for k in keepers:
			var own_goal: Vector3 = main.home_team.own_goal_pos if k.team_id == 0 \
				else main.away_team.own_goal_pos
			var intent: int = AIController.gk_intent(k, ball, own_goal)
			var name: String = AIController.GKIntent.keys()[intent]
			intent_frames[name] = intent_frames.get(name, 0) + 1
			if i % 6 == 0:
				var off: float = absf(k.global_position.x - own_goal.x)
				off_line_sum += off
				off_line_max = maxf(off_line_max, off)
				samples += 1

		# A chance: the ball inside CHANCE_RANGE of either goal, counted once
		# per approach rather than per frame.
		var near_goal := false
		for k in keepers:
			var og: Vector3 = main.home_team.own_goal_pos if k.team_id == 0 \
				else main.away_team.own_goal_pos
			if ball.global_position.distance_to(og) < CHANCE_RANGE:
				near_goal = true
		if near_goal and not in_chance:
			in_chance = true
			chances += 1
		elif not near_goal:
			in_chance = false
			approach_min = {0: INF, 1: INF}
		if near_goal:
			for k in keepers:
				approach_min[k.team_id] = minf(approach_min[k.team_id],
					k.global_position.distance_to(ball.global_position))

		# Rolling history, because the score changes AFTER the goal is
		# detected and the players have already been reset to kickoff. Reading
		# the keeper on the frame the score moves measures them standing on the
		# centre spot -- which is why the first version of this reported an
		# identical 1.56 m / 24.44 m for every goal. What matters is where they
		# were while the shot was arriving.
		var snap: Array = []
		for k in keepers:
			var og2: Vector3 = main.home_team.own_goal_pos if k.team_id == 0 \
				else main.away_team.own_goal_pos
			snap.append({
				"team": k.team_id,
				"intent": AIController.GKIntent.keys()[AIController.gk_intent(k, ball, og2)],
				"off_line": absf(k.global_position.x - og2.x),
				"to_ball": k.global_position.distance_to(ball.global_position),
				"ball_speed": ball.linear_velocity.length(),
			})
		history.append(snap)
		while history.size() > HISTORY_FRAMES:
			history.pop_front()

		if main.home_score != last_home or main.away_score != last_away:
			var conceded_by: int = 0 if main.away_score != last_away else 1
			last_home = main.home_score
			last_away = main.away_score
			# Half a second before the score moved: the ball is still in flight.
			var past: Array = history[0] if not history.is_empty() else []
			for entry in past:
				if entry["team"] != conceded_by:
					continue
				goals.append({
					"t": i / 60.0,
					"team": conceded_by,
					"intent": entry["intent"],
					"off_line": entry["off_line"],
					"to_ball": entry["to_ball"],
					"ball_speed": entry["ball_speed"],
					"closest": approach_min.get(conceded_by, INF),
				})

	print("KEEPER: ================ RESULT ================")
	print("KEEPER: final score %d - %d over %ds (%.1f goals/min)" % [
		main.home_score, main.away_score, SECONDS,
		60.0 * (main.home_score + main.away_score) / float(SECONDS)])
	print("KEEPER: approaches inside %.0f m of a goal: %d" % [CHANCE_RANGE, chances])
	print("KEEPER: ---- intent distribution (both keepers, every frame) ----")
	var total := 0
	for k in intent_frames:
		total += intent_frames[k]
	var keys: Array = intent_frames.keys()
	keys.sort_custom(func(a, b): return intent_frames[a] > intent_frames[b])
	for k in keys:
		print("KEEPER:   %-18s %5.1f%%" % [k, 100.0 * intent_frames[k] / maxf(total, 1)])
	print("KEEPER: off the goal line: mean %.2f m, worst %.2f m" % [
		off_line_sum / maxf(samples, 1), off_line_max])
	print("KEEPER: ---- committed dives ----")
	var dive_total := 0
	for k in saves:
		dive_total += saves[k]
	print("KEEPER:   %d dives committed (%.1f per minute across both keepers)" % [
		dive_total, 60.0 * dive_total / float(SECONDS)])
	for k in saves:
		print("KEEPER:     %-8s %d" % [k, saves[k]])
	print("KEEPER: ---- goals conceded ----")
	for g in goals:
		print("KEEPER:   t=%6.1fs team %d conceded; 0.5 s earlier %s, %.2f m off line, %.2f m from ball (%.1f m/s); CLOSEST ALL APPROACH %.2f m" % [
			g["t"], g["team"], g["intent"], g["off_line"], g["to_ball"],
			g["ball_speed"], g["closest"]])
	get_tree().quit()
