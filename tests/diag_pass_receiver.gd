extends Node3D

## v0.9.1 diagnostic: does an AI ever deliberately pass to an OPPONENT?
##
## Human QA reports bots passing "directly to enemies as though they are
## valid receivers". Two very different things look identical on screen:
##
##   TARGETING  -- the evaluator selected an opponent as the receiver. A
##                 correctness bug, and the thing the milestone forbids.
##   INTERCEPT  -- the evaluator selected a teammate and an opponent got
##                 there first. Legal football, and explicitly allowed.
##
## Fixing the second by adding an "if opponent, cancel" check would be
## meaningless, so this separates them before anything is changed. For every
## kick it records the passer's team, the INTENDED receiver's team, whether
## that receiver was actually in the passer's own teammates array, and who
## first reached the ball afterwards.
##
## It also watches for the specific failure modes the brief names: a stale
## target surviving a possession change, and a LEAD pass -- whose aim point
## is a position in space rather than a player -- being collected by the
## other side.

const MainScene := preload("res://scenes/Main.tscn")

const SECONDS := 90


func _ready() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	await get_tree().physics_frame
	for i in range(120):
		await get_tree().physics_frame

	var players: Array = main.home_players + main.away_players
	var ball: RigidBody3D = main.ball

	var kick_counts := {}
	var passes := 0
	var targeted_opponent := 0
	var target_not_in_teammates := 0
	var target_invalid := 0
	var lead_passes := 0
	var lead_to_opponent := 0
	var normal_to_opponent := 0
	var reached_intended := 0
	var intercepted := 0
	# Kicks awaiting an outcome: [passer, intended, kind, frames]
	var pending: Array = []

	for i in range(SECONDS * 60):
		await get_tree().physics_frame

		# Resolve outstanding passes: who actually got to the ball first?
		var still: Array = []
		for e in pending:
			var passer: FootballPlayer = e[0]
			var intended: FootballPlayer = e[1]
			e[3] += 1
			var claimer: FootballPlayer = null
			for p in players:
				if p == passer:
					continue
				var d: float = Vector2(ball.global_position.x - p.global_position.x,
					ball.global_position.z - p.global_position.z).length()
				if d <= FootballPlayer.POSSESSION_CONTACT_RADIUS and p.has_possession:
					claimer = p
					break
			if claimer != null:
				if claimer == intended:
					reached_intended += 1
				elif claimer.team_id != passer.team_id:
					intercepted += 1
					if e[2] == PassEvaluator.PassKind.LEAD:
						lead_to_opponent += 1
					else:
						normal_to_opponent += 1
			elif e[3] < 180:
				still.append(e)
		pending = still

		for p in players:
			var seen: int = kick_counts.get(p, -1)
			if seen >= 0 and p.kick_count > seen and p.last_kick_kind == FootballPlayer.KickKind.PASS:
				passes += 1
				var t: FootballPlayer = p.last_kick_target
				if t == null:
					pass  # a knock into space, no intended receiver
				else:
					if not is_instance_valid(t):
						target_invalid += 1
					else:
						# THE question: was the selected receiver an opponent?
						if t.team_id != p.team_id:
							targeted_opponent += 1
						if not (t in p.teammates):
							target_not_in_teammates += 1
					if p.last_pass_kind == PassEvaluator.PassKind.LEAD:
						lead_passes += 1
					pending.append([p, t, p.last_pass_kind, 0])
			kick_counts[p] = p.kick_count

	print("DIAG-RECV: %d AI passes over %ds" % [passes, SECONDS])
	print("DIAG-RECV:   selected an OPPONENT as receiver : %d   <-- must be 0" % targeted_opponent)
	print("DIAG-RECV:   receiver not in own teammates[]  : %d   <-- must be 0" % target_not_in_teammates)
	print("DIAG-RECV:   receiver invalid at kick time    : %d" % target_invalid)
	print("DIAG-RECV:   lead passes (aimed into space)   : %d" % lead_passes)
	print("DIAG-RECV: outcomes -- reached intended %d, intercepted by opponent %d" % [
		reached_intended, intercepted])
	print("DIAG-RECV:   of those interceptions: %d after a LEAD pass, %d after a normal pass" % [
		lead_to_opponent, normal_to_opponent])
	get_tree().quit()
