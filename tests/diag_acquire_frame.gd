extends Node3D

## v0.9.0 diagnostic: the ACQUISITION frame, not the election frame.
##
## The previous pass established that 32% of steals are seen at more than
## POSSESSION_CONTACT_RADIUS (1.20m), worst 3.17m -- further than any sensor
## in the system reaches. That rules out both "acquired by contact" and
## "acquired by tackle" as the whole story, so this measures the moment
## has_possession actually flips false->true for each player, which is the
## only place the contact gate is enforced.
##
## Three candidate mechanisms are separated:
##
##   ACQUIRED AT   -- gap on the frame has_possession became true. The
##                    contact gate should make this <= 1.20m, always.
##   ELECTED AT    -- gap on the frame PossessionManager made them carrier.
##                    Larger than the above means the ball moved between
##                    acquiring and being elected.
##   HELD OUT TO   -- how far the ball got while has_possession stayed true.
##                    POSSESSION_GRACE (0.15s) deliberately keeps the flag
##                    alive after the ball leaves the control radius, and
##                    PossessionManager elects from that flag -- so a player
##                    can be "the carrier" with the ball metres away.

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

	var acquired: Array = []
	var elected: Array = []
	var held_out_to: Array = []
	var had_possession := {}
	var prev_carrier: FootballPlayer = null
	# Worst gap seen while a player still counted as having possession.
	var worst_while_held := {}

	for i in range(SECONDS * 60):
		await get_tree().physics_frame

		for p in players:
			var gap: float = _gap(p, ball)
			var was: bool = had_possession.get(p, false)
			if p.has_possession:
				if not was:
					acquired.append(gap)
					worst_while_held[p] = gap
				else:
					worst_while_held[p] = maxf(worst_while_held.get(p, 0.0), gap)
			elif was:
				held_out_to.append(worst_while_held.get(p, 0.0))
			had_possession[p] = p.has_possession

		var carrier: FootballPlayer = pm.current_carrier
		if carrier != null and prev_carrier != null and carrier != prev_carrier \
			and carrier.team_id != prev_carrier.team_id:
			elected.append(_gap(carrier, ball))
		prev_carrier = carrier

	_report("ACQUIRED AT (contact gate applies here)", acquired,
		FootballPlayer.POSSESSION_CONTACT_RADIUS)
	_report("ELECTED AT  (what a human sees as a steal)", elected,
		FootballPlayer.POSSESSION_CONTACT_RADIUS)
	_report("HELD OUT TO (ball's furthest while still 'his')", held_out_to,
		FootballPlayer.POSSESSION_CONTACT_RADIUS)
	print("DIAG-ACQ: gates -- contact %.2fm, possession grace %.2fs, control radius ~1.55-1.90m" % [
		FootballPlayer.POSSESSION_CONTACT_RADIUS, FootballPlayer.POSSESSION_GRACE])
	get_tree().quit()


func _gap(p: FootballPlayer, ball: RigidBody3D) -> float:
	return Vector2(ball.global_position.x - p.global_position.x,
		ball.global_position.z - p.global_position.z).length()


func _report(label: String, vals: Array, gate: float) -> void:
	if vals.is_empty():
		print("DIAG-ACQ: %s -- none" % label)
		return
	var sum := 0.0
	var worst := 0.0
	var over := 0
	for v in vals:
		sum += v
		worst = maxf(worst, v)
		if v > gate:
			over += 1
	print("DIAG-ACQ: %s" % label)
	print("DIAG-ACQ:    %d events, mean %.2fm, worst %.2fm, %d (%.0f%%) beyond %.2fm" % [
		vals.size(), sum / vals.size(), worst, over, 100.0 * over / vals.size(), gate])
