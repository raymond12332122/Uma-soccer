extends Node3D

## v0.9.2.3 section 6: trace EVERY possession transfer.
##
## Human QA reports that AI can again steal the ball from unrealistic
## distances without believable physical contact, after that had previously
## been substantially fixed. The brief asks for the transfer itself to be
## logged rather than for the possession code to be re-read, so this records
## the fourteen fields section 6 lists, on the exact frame the carrier
## changes:
##
##   old carrier / new carrier / teams
##   ball position, old-carrier position, new-carrier position
##   ball-to-new-carrier distance
##   body-to-body distance
##   acquisition reason
##   challenge state, tackle state
##   contact/collision evidence
##   ball speed, whether the ball was controllable
##   any grace or exemption that was active
##
## The verdict column is the one that matters. A transfer is LEGITIMATE when
## the ball was inside the acquiring player's gate at the moment they took it
## (POSSESSION_CONTACT_RADIUS, or CONTEST_WIN_REACH while a contest-win grace
## is open). Anything else is a steal from outside the established physical
## acquisition geometry, and is exactly what QA is describing.

const MainScene := preload("res://scenes/Main.tscn")
const SECONDS := 90

## How far back to look for physical contact between the two players. A
## challenge that produced contact half a second before the ball changed
## hands is still a challenge; one with no contact in that whole window took
## the ball without touching anybody.
const CONTACT_WINDOW := 0.6
const CONTACT_DISTANCE := SlideTackle.BODY_CONTACT

var _main: Node3D
var _players: Array = []
var _ball: RigidBody3D
var _pm: PossessionManager

var _prev_carrier: FootballPlayer = null
var _time := 0.0
var _transfers: Array = []

## Who last held the ball before it went loose, where they were, and when. See
## _sample() for why a possession trace that ignores the loose window cannot
## see the steal QA is describing.
var _loose_from: FootballPlayer = null
var _loose_from_pos := Vector3.ZERO
var _loose_since := 0.0

## How briefly the ball can be ownerless and the sequence still count as one
## continuous turnover rather than a genuine loose ball somebody ran onto.
const LOOSE_TURNOVER_WINDOW := 0.5

## Rolling per-pair body-gap minimum, so "was there contact" is answered from
## measurement rather than from the frame the transfer happened to land on.
var _gap_history: Array = []

## Slide outcomes, captured from the signal so the tackle state at the moment
## of transfer is what actually happened rather than an inference.
var _slides := {}

## Every slide outcome per player, for the rate report.
var _slide_log := {}

## Ball gap captured on the exact frame possession was granted -- see
## _on_possession().
var _exact_gap := {}


func _ready() -> void:
	_main = MainScene.instantiate()
	add_child(_main)
	for i in range(90):
		await get_tree().physics_frame
	_players = _main.home_players + _main.away_players
	_ball = _main.ball
	_pm = _main.possession_manager
	for p in _players:
		p.slide_resolved.connect(_on_slide.bind(p))
		p.possession_changed.connect(_on_possession.bind(p))
	print("TRANSFER: tracing %d players for %ds" % [_players.size(), SECONDS])
	print("TRANSFER: gates -- contact %.2f  contest-win reach %.2f  grace %.2fs" % [
		FootballPlayer.POSSESSION_CONTACT_RADIUS,
		FootballPlayer.CONTEST_WIN_REACH,
		FootballPlayer.CONTEST_WIN_GRACE])

	for i in range(SECONDS * 60):
		await get_tree().physics_frame
		_time += 1.0 / 60.0
		_sample()

	_report()
	get_tree().quit()


## The acquisition frame itself.
##
## Polling from _physics_process reads the world one physics step AFTER
## possession was granted, and a ball doing 3 m/s has already moved 0.05 m by
## then. That showed up as a run of acquisitions measuring 1.24-1.27 m against
## a 1.20 m gate -- a consistent overshoot that looked like a defect and was
## sampling lag. FootballPlayer emits this the moment it grants possession, so
## the geometry recorded here is the geometry the gate actually saw.
func _on_possession(info: Dictionary, who: FootballPlayer) -> void:
	if str(info.get("kind", "")) != "gained":
		return
	_exact_gap[who] = _flat(_ball.global_position).distance_to(
		_flat(who.global_position))


func _on_slide(info: Dictionary, who: FootballPlayer) -> void:
	if not _slide_log.has(who):
		_slide_log[who] = []
	_slide_log[who].append(str(info.get("outcome_name", "")))
	_slides[who] = {"t": _time, "outcome": str(info.get("outcome_name", "")),
		"played_ball": bool(info.get("played_ball", false)),
		"hit_player": bool(info.get("hit_player", false))}


func _sample() -> void:
	# Rolling contact record between every opposing pair that is close enough
	# to matter. Cheap: only pairs already inside a couple of metres.
	var frame_pairs := {}
	for i in range(_players.size()):
		for j in range(i + 1, _players.size()):
			var a: FootballPlayer = _players[i]
			var b: FootballPlayer = _players[j]
			if a.team_id == b.team_id:
				continue
			var g: float = _flat(a.global_position).distance_to(_flat(b.global_position))
			if g < 3.0:
				frame_pairs["%s|%s" % [a.name, b.name]] = g
	_gap_history.append({"t": _time, "pairs": frame_pairs})
	while _gap_history.size() > 0 and _time - _gap_history[0]["t"] > CONTACT_WINDOW:
		_gap_history.pop_front()

	var carrier: FootballPlayer = _pm.current_carrier
	if carrier == _prev_carrier:
		return
	if carrier == null:
		# The ball has gone loose. Remember who had it and when, because the
		# thing QA describes as a steal usually arrives through here rather
		# than as a direct carrier-to-carrier swap: the carrier loses the ball
		# to RETAIN_MAX_DISTANCE or a knock, it is ownerless for a handful of
		# frames, and an opponent collects. Treating that as an innocent
		# "loose pickup" is how a real steal hides from a possession trace --
		# it was the first blind spot this diagnostic had.
		_loose_from = _prev_carrier
		_loose_since = _time
		if _prev_carrier != null and is_instance_valid(_prev_carrier):
			_loose_from_pos = _prev_carrier.global_position
	else:
		_log_transfer(_prev_carrier, carrier)
	_prev_carrier = carrier


func _log_transfer(from: FootballPlayer, to: FootballPlayer) -> void:
	# Fold the loose window back in: if the ball was ownerless only briefly
	# and somebody else's player collects it, that is one turnover, not an
	# innocent loose pickup, and it has to face the same verdict.
	var loose_for := -1.0
	if from == null and _loose_from != null and is_instance_valid(_loose_from) \
		and _loose_from != to and _time - _loose_since <= LOOSE_TURNOVER_WINDOW:
		from = _loose_from
		loose_for = _time - _loose_since

	var ball_pos: Vector3 = _ball.global_position
	var to_pos: Vector3 = to.global_position
	var polled_gap: float = _flat(ball_pos).distance_to(_flat(to_pos))
	var ball_gap: float = float(_exact_gap.get(to, polled_gap))
	var body_gap := -1.0
	var from_pos := Vector3.INF
	var same_team := false
	if from != null and is_instance_valid(from):
		from_pos = from.global_position
		body_gap = _flat(from_pos).distance_to(_flat(to_pos))
		same_team = from.team_id == to.team_id

	var ball_speed: float = _ball.linear_velocity.length()
	var rel_speed: float = (_ball.linear_velocity - to.velocity).length()
	var contest_grace: float = to._contest_win_timer
	var challenge: float = to.challenge_progress

	# The gate that was actually in force on this frame.
	var gate: float = FootballPlayer.POSSESSION_CONTACT_RADIUS
	if contest_grace > 0.0:
		gate = maxf(gate, FootballPlayer.CONTEST_WIN_REACH)

	# Measured contact evidence over the window, not an assumption.
	var min_gap := INF
	if from != null and is_instance_valid(from):
		var k1: String = "%s|%s" % [from.name, to.name]
		var k2: String = "%s|%s" % [to.name, from.name]
		for h in _gap_history:
			if h["pairs"].has(k1):
				min_gap = minf(min_gap, h["pairs"][k1])
			elif h["pairs"].has(k2):
				min_gap = minf(min_gap, h["pairs"][k2])

	var slide: Dictionary = _slides.get(to, {})
	var slide_recent: bool = not slide.is_empty() and _time - float(slide["t"]) < 1.0

	var reason := "LOOSE_PICKUP"
	if from == null or not is_instance_valid(from):
		reason = "LOOSE_PICKUP"
	elif loose_for >= 0.0 and not same_team and challenge <= 0.0 and contest_grace <= 0.0:
		# Took it off an opponent through a short loose window with no
		# challenge of their own. This is the shape of the steal QA reports.
		reason = "VIA_LOOSE_NO_CHALLENGE"
	elif same_team:
		reason = "SAME_TEAM"
	elif slide_recent and str(slide.get("outcome", "")) == "CLEAN_TACKLE":
		reason = "SLIDE_CLEAN"
	elif contest_grace > 0.0:
		reason = "CONTEST_WIN_GRACE"
	elif challenge > 0.0:
		reason = "CHALLENGE_PRESSURE"
	else:
		reason = "NO_CHALLENGE"

	var verdict := "LEGITIMATE"
	if ball_gap > gate + 0.02:
		verdict = "OUTSIDE_GATE"
	elif not same_team and from != null and is_instance_valid(from) \
		and min_gap > CONTACT_DISTANCE \
		and (reason == "NO_CHALLENGE" or reason == "VIA_LOOSE_NO_CHALLENGE"):
		verdict = "NO_CONTACT_NO_CHALLENGE"

	_transfers.append({
		"t": _time, "from": from, "to": to, "same_team": same_team,
		"ball_gap": ball_gap, "body_gap": body_gap, "reason": reason,
		"verdict": verdict, "gate": gate, "min_gap": min_gap,
		"challenge": challenge, "grace": contest_grace,
		"ball_speed": ball_speed, "rel_speed": rel_speed,
		"slide": slide_recent, "loose_for": loose_for,
	})

	print("TRANSFER: t=%6.2f  %-22s -> %-22s  %s" % [
		_time,
		("(loose)" if from == null else "%s[%d]" % [from.name, from.team_id]),
		"%s[%d]" % [to.name, to.team_id],
		("SAME-TEAM" if same_team else "TURNOVER")
			+ ("" if loose_for < 0.0 else "  (via %.2fs loose)" % loose_for)])
	print("TRANSFER:    ball=(%.2f, %.2f, %.2f)  old=(%s)  new=(%.2f, %.2f, %.2f)" % [
		ball_pos.x, ball_pos.y, ball_pos.z,
		("n/a" if from == null else "%.2f, %.2f, %.2f" % [from_pos.x, from_pos.y, from_pos.z]),
		to_pos.x, to_pos.y, to_pos.z])
	print("TRANSFER:    ball->new %.2f at the acquisition frame (%.2f when polled), gate %.2f" % [
		ball_gap, polled_gap, gate])
	print("TRANSFER:    body->body %.2f  closest contact in %.1fs: %s" % [
		body_gap, CONTACT_WINDOW,
		("none" if min_gap == INF else "%.2f" % min_gap)])
	print("TRANSFER:    reason=%s  challenge=%.2f  contest_grace=%.2f  slide=%s%s" % [
		reason, challenge, contest_grace, str(slide_recent),
		("" if slide.is_empty() else " (%s played_ball=%s hit=%s)" % [
			slide.get("outcome", ""), str(slide.get("played_ball", false)),
			str(slide.get("hit_player", false))])])
	print("TRANSFER:    ball speed %.2f m/s  relative %.2f (controllable <= %.2f)  slide_state=%s/%.2f" % [
		ball_speed, rel_speed, FootballPlayer.CONTROLLED_BALL_SPEED,
		str(to.is_sliding), to.slide_recovery])
	print("TRANSFER:    VERDICT %s" % verdict)


func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


func _report() -> void:
	print("TRANSFER: ================ RESULT ================")
	var turnovers: Array = []
	for t in _transfers:
		if not t["same_team"] and t["from"] != null:
			turnovers.append(t)
	print("TRANSFER: %d carrier changes, %d of them opponent turnovers" % [
		_transfers.size(), turnovers.size()])

	var reasons := {}
	var verdicts := {}
	var worst := 0.0
	var worst_line := ""
	var sum_gap := 0.0
	for t in turnovers:
		reasons[t["reason"]] = reasons.get(t["reason"], 0) + 1
		verdicts[t["verdict"]] = verdicts.get(t["verdict"], 0) + 1
		sum_gap += t["ball_gap"]
		if t["ball_gap"] > worst:
			worst = t["ball_gap"]
			worst_line = "t=%.2f %s -> %s ball_gap %.2f gate %.2f reason %s" % [
				t["t"], t["from"].name, t["to"].name, t["ball_gap"], t["gate"], t["reason"]]

	print("TRANSFER: ---- turnover acquisition reason ----")
	for k in reasons:
		print("TRANSFER:   %-20s %d" % [k, reasons[k]])
	print("TRANSFER: ---- verdict ----")
	for k in verdicts:
		print("TRANSFER:   %-24s %d" % [k, verdicts[k]])
	if not turnovers.is_empty():
		print("TRANSFER: mean ball->new-carrier distance at turnover: %.2f m" % [
			sum_gap / turnovers.size()])
		print("TRANSFER: worst: %s" % worst_line)

	# The headline number: how many turnovers happened with the ball outside
	# the acquiring player's own gate. In a correct build this is zero.
	var outside: int = verdicts.get("OUTSIDE_GATE", 0)
	print("TRANSFER: TURNOVERS FROM OUTSIDE THE ACQUISITION GATE: %d" % outside)
	print("TRANSFER: turnovers with no contact and no challenge: %d" % [
		verdicts.get("NO_CONTACT_NO_CHALLENGE", 0)])

	# How often does the v0.9.2.1 slide actually fire, and what does it
	# produce? This is the one behaviour added to the challenge path since QA
	# last accepted the steal geometry, so its RATE matters as much as its
	# reach: a legal tackle thrown constantly still reads as defenders
	# magnetically taking the ball.
	print("TRANSFER: ---- committed slides ----")
	var by_outcome := {}
	for who in _slide_log:
		for s in _slide_log[who]:
			by_outcome[s] = by_outcome.get(s, 0) + 1
	var total_slides := 0
	for k in by_outcome:
		total_slides += by_outcome[k]
	print("TRANSFER:   %d slides in %ds (%.1f per minute across %d players)" % [
		total_slides, SECONDS, 60.0 * total_slides / maxf(SECONDS, 1),
		_players.size()])
	for k in by_outcome:
		print("TRANSFER:   %-16s %d" % [k, by_outcome[k]])
	var slide_turnovers := 0
	for t in turnovers:
		if t["slide"]:
			slide_turnovers += 1
	print("TRANSFER:   turnovers attributable to a slide: %d of %d" % [
		slide_turnovers, turnovers.size()])
