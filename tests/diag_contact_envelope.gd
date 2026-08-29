extends Node3D

## v0.9.1 diagnostic: how far away is a player when they actually TOUCH the
## ball -- poke it, tackle it away, or take it into their own possession?
##
## The brief asks for DISTRIBUTIONS rather than maxima, and for the moment of
## the ball ACTION to be separated from the moment of possession change. Those
## are three different events and they are sampled separately here:
##
##   TACKLE       -- challenge_progress collapses from near-complete to zero,
##                   i.e. the frame a defender pokes the ball away
##   ACQUIRE      -- the frame FootballPlayer.has_possession goes false->true,
##                   which is where the contact gate is actually enforced
##   CARRIER FLIP -- PossessionManager elects a new carrier. This lags ACQUIRE
##                   by the manager's confirmation window, so the player has
##                   moved on by the time it fires; it is reported only to
##                   show how misleading it is as a measure of reach.
##
## Distances are reported three ways, because "how close was he" has three
## different honest answers:
##
##   CENTRE     -- player centre to ball centre, the number the code gates on
##   SURFACE    -- minus the player's capsule radius and the ball's, i.e. the
##                 gap between the two bodies
##   REACH      -- surface distance minus a leg's reach; at or below zero a
##                 foot can genuinely get there

const MainScene := preload("res://scenes/Main.tscn")

const SECONDS := 180
const CAPSULE_R := 0.4
const BALL_R := 0.16
const LEG_REACH := 0.55


func _ready() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	await get_tree().physics_frame
	for i in range(120):
		await get_tree().physics_frame

	var players: Array = main.home_players + main.away_players
	var ball: RigidBody3D = main.ball
	var pm: PossessionManager = main.possession_manager

	var tackle_d: Array = []
	var flip_d: Array = []
	var acquire_loose: Array = []
	var acquire_steal: Array = []
	var acquire_by_contest: int = 0
	var steal_after_tackle: int = 0
	var steal_while_challenging: int = 0
	var steal_no_challenge: int = 0
	var prev_progress := {}
	var prev_has := {}
	var prev_carrier: FootballPlayer = null
	var last_holder: FootballPlayer = null

	for i in range(SECONDS * 60):
		await get_tree().physics_frame

		for p in players:
			# A tackle: challenge_progress collapses from near-complete to zero.
			var was: float = prev_progress.get(p, 0.0)
			if was >= BallContest.CHALLENGE_TIME_REQUIRED * 0.9 and p.challenge_progress < was * 0.5:
				tackle_d.append(_gap(p, ball))
			prev_progress[p] = p.challenge_progress

			# An acquisition: the exact frame the possession gate opened.
			var had: bool = prev_has.get(p, false)
			if p.has_possession and not had:
				var d: float = _gap(p, ball)
				if last_holder != null and is_instance_valid(last_holder) \
					and last_holder != p and last_holder.team_id != p.team_id:
					acquire_steal.append(d)
					# THE question behind "unrealistic near kicks": did this
					# player DO anything to win it, or did they just be near?
					if p._contest_win_timer > 0.0:
						steal_after_tackle += 1
					elif was > 0.0:
						steal_while_challenging += 1
					else:
						steal_no_challenge += 1
				else:
					acquire_loose.append(d)
				if p._contest_win_timer > 0.0:
					acquire_by_contest += 1
			if p.has_possession:
				last_holder = p
			prev_has[p] = p.has_possession

		var carrier: FootballPlayer = pm.current_carrier
		if carrier != null and prev_carrier != null and carrier != prev_carrier \
			and carrier.team_id != prev_carrier.team_id:
			flip_d.append(_gap(carrier, ball))
		prev_carrier = carrier

	_report("TACKLE   (ball poked away)  ", tackle_d)
	_report("ACQUIRE  (loose ball)       ", acquire_loose)
	_report("ACQUIRE  (taken off an opp) ", acquire_steal)
	_report("CARRIER FLIP (manager, lags)", flip_d)
	var steals: int = steal_after_tackle + steal_while_challenging + steal_no_challenge
	if steals > 0:
		print("DIAG-ENV: how the ball was taken off an opponent (n=%d):" % steals)
		print("DIAG-ENV:    after winning a tackle          : %d (%.0f%%)" % [
			steal_after_tackle, 100.0 * steal_after_tackle / steals])
		print("DIAG-ENV:    while a challenge was building  : %d (%.0f%%)" % [
			steal_while_challenging, 100.0 * steal_while_challenging / steals])
		print("DIAG-ENV:    NO challenge at all, pure proximity: %d (%.0f%%)  <-- the 'walked up and took it' case" % [
			steal_no_challenge, 100.0 * steal_no_challenge / steals])
	print("DIAG-ENV: acquisitions using the contest-win reach exemption: %d" % acquire_by_contest)
	print("DIAG-ENV: gates -- awareness/challenge %.2fm, poke reach %.2fm, contact %.2fm, contest reach %.2fm" % [
		BallContest.CHALLENGE_RANGE, BallContest.POKE_REACH,
		FootballPlayer.POSSESSION_CONTACT_RADIUS, FootballPlayer.CONTEST_WIN_REACH])
	print("DIAG-ENV: physically reachable centre-to-centre = capsule %.2f + ball %.2f + leg %.2f = %.2fm" % [
		CAPSULE_R, BALL_R, LEG_REACH, CAPSULE_R + BALL_R + LEG_REACH])
	get_tree().quit()


func _gap(p: FootballPlayer, ball: RigidBody3D) -> float:
	return Vector2(ball.global_position.x - p.global_position.x,
		ball.global_position.z - p.global_position.z).length()


func _report(label: String, d: Array) -> void:
	if d.is_empty():
		print("DIAG-ENV: %s none" % label)
		return
	d.sort()
	var n: int = d.size()
	var sum := 0.0
	for v in d:
		sum += v
	var med: float = d[n / 2]
	var p90: float = d[int(n * 0.9)] if n > 1 else d[0]
	print("DIAG-ENV: %s n=%d" % [label, n])
	print("DIAG-ENV:    centre-to-ball  min %.2f  median %.2f  p90 %.2f  max %.2f  mean %.2f" % [
		d[0], med, p90, d[n - 1], sum / n])
	print("DIAG-ENV:    body surface    median %.2f  max %.2f" % [
		maxf(med - CAPSULE_R - BALL_R, 0.0), maxf(d[n - 1] - CAPSULE_R - BALL_R, 0.0)])
	var over: int = _count_over(d, CAPSULE_R + BALL_R + LEG_REACH)
	print("DIAG-ENV:    beyond a leg's reach: %d of %d (%.0f%%)" % [over, n, 100.0 * over / n])


func _count_over(d: Array, limit: float) -> int:
	var c := 0
	for v in d:
		if v > limit:
			c += 1
	return c
