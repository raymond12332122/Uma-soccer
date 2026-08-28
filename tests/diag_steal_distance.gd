extends Node3D

## v0.9.0 diagnostic: at what distance does a steal ACTUALLY happen?
##
## The human playtest reports that AI still takes the ball from unrealistic
## distances, while v0.8.8's regression suite says every acquisition happens
## within POSSESSION_CONTACT_RADIUS (1.20m). Both can be true: that suite
## measures the distance at which a player CLAIMS the ball, and the distance
## from which a KICK is struck. Neither measures the distance from which a
## TACKLE completes, and a tackle is the other way possession changes hands.
##
## BallContest.challenge_rate returns 0 only beyond CHALLENGE_RANGE (2.4m),
## so a challenge can be built -- and completed -- from well outside contact
## range; _apply_tackle then knocks the ball toward the winner and calls
## notify_possession_won_from_opponent(), which opens CONTEST_WIN_GRACE and
## explicitly EXEMPTS them from the contact gate for its duration.
##
## This records every possession change between opponents, separated by the
## mechanism that caused it, with the geometry at the moment it happened.

const MainScene := preload("res://scenes/Main.tscn")

const SECONDS := 60


func _ready() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	await get_tree().physics_frame
	for i in range(120):
		await get_tree().physics_frame

	var pm: PossessionManager = main.possession_manager
	var ball: RigidBody3D = main.ball
	var players: Array = main.home_players + main.away_players

	# Distances at which a steal completed, split by mechanism.
	var tackle_dists: Array = []
	var claim_dists: Array = []
	# Peak challenge progress seen, to show challenges are really building.
	var peak_progress := 0.0
	# Peak challenge progress each player has reached in the last WINDOW
	# frames. A one-frame lookback does NOT work: _apply_tackle zeroes the
	# winner's progress immediately, but PossessionManager only elects them
	# carrier once their own _update_possession has run under the contest
	# grace, which is a few frames later -- by then the previous frame's
	# value is already 0 and every tackle misreads as a plain claim.
	var WINDOW := 30
	var recent_peak := {}
	var prev_carrier: FootballPlayer = null
	# Was the winner still inside CONTEST_WIN_GRACE when they claimed it?
	# That grace deliberately EXEMPTS them from the contact gate.
	var claimed_under_grace := 0

	for i in range(SECONDS * 60):
		await get_tree().physics_frame
		var carrier: FootballPlayer = pm.current_carrier

		for p in players:
			peak_progress = maxf(peak_progress, p.challenge_progress)

		if carrier != null and prev_carrier != null and carrier != prev_carrier \
			and carrier.team_id != prev_carrier.team_id:
			var d: float = Vector2(
				ball.global_position.x - carrier.global_position.x,
				ball.global_position.z - carrier.global_position.z).length()
			# A winner who had built a near-complete challenge in the last
			# half-second took the ball by TACKLE; anyone else simply got to
			# a ball that was already free of its previous owner.
			if carrier._contest_win_timer > 0.0:
				claimed_under_grace += 1
			var peak: float = recent_peak.get(carrier, 0.0)
			if peak >= BallContest.CHALLENGE_TIME_REQUIRED * 0.9:
				tackle_dists.append(d)
			else:
				claim_dists.append(d)

		for p in players:
			var decayed: float = recent_peak.get(p, 0.0) - (1.0 / float(WINDOW))
			recent_peak[p] = maxf(maxf(decayed, 0.0), p.challenge_progress)
		prev_carrier = carrier

	_report("STEAL BY TACKLE      ", tackle_dists)
	_report("STEAL BY CLAIM       ", claim_dists)
	print("DIAG-STEAL: peak challenge progress seen: %.2f (needs %.2f)" % [
		peak_progress, BallContest.CHALLENGE_TIME_REQUIRED])
	print("DIAG-STEAL: steals claimed while still inside CONTEST_WIN_GRACE: %d" % claimed_under_grace)
	print("DIAG-STEAL: gates -- contact %.2fm, challenge range %.2fm, contest grace %.2fs" % [
		FootballPlayer.POSSESSION_CONTACT_RADIUS, BallContest.CHALLENGE_RANGE,
		FootballPlayer.CONTEST_WIN_GRACE])
	get_tree().quit()


func _report(label: String, dists: Array) -> void:
	if dists.is_empty():
		print("DIAG-STEAL: %s none" % label)
		return
	var sum := 0.0
	var worst := 0.0
	var over_contact := 0
	for d in dists:
		sum += d
		worst = maxf(worst, d)
		if d > FootballPlayer.POSSESSION_CONTACT_RADIUS:
			over_contact += 1
	print("DIAG-STEAL: %s %d events, mean %.2fm, worst %.2fm, %d (%.0f%%) beyond contact radius" % [
		label, dists.size(), sum / dists.size(), worst,
		over_contact, 100.0 * over_contact / dists.size()])
