extends Node3D

## v0.9.2.1: why does nobody slide? (brief sections 5-7)
##
## The first cut of the commit conditions produced ZERO slides over a
## 60-second match. Rather than loosening numbers until some appear -- which
## would be tuning against a test instead of against the game -- this measures
## what defenders near a carrier are actually doing, so the thresholds can be
## set from the distribution.
##
## For every frame where an opponent is within a generous radius of the
## carrier, it records that defender's gap, speed, how directly they are
## closing, their accumulated challenge progress, and whether the ball is
## already inside their poking reach. Then it reports how often each
## individual condition would have been satisfied, and how often ALL of them
## were at once -- which is the number that was zero.

const MainScene := preload("res://scenes/Main.tscn")
const SECONDS := 60
const WATCH_RADIUS := 5.0

## Candidate commit rule under evaluation.
const CAND_MIN_GAP := 2.0
const CAND_MAX_GAP := 3.6
const CAND_MIN_SPEED := 4.0
const CAND_MIN_APPROACH := 0.60

var _samples := 0
var _pass_gap := 0
var _pass_speed := 0
var _pass_approach := 0
var _pass_progress := 0
var _pass_outside_poke := 0
var _pass_all := 0
var _pass_candidate := 0
var _gaps: Array = []
var _speeds: Array = []
var _progress: Array = []


func _ready() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(90):
		await get_tree().physics_frame

	var pm: PossessionManager = main.possession_manager
	var players: Array = main.home_players + main.away_players
	var ball: RigidBody3D = main.ball

	for i in range(SECONDS * 60):
		await get_tree().physics_frame
		var carrier: FootballPlayer = pm.current_carrier if pm != null else null
		if carrier == null or not is_instance_valid(carrier):
			continue
		for p in players:
			if p == carrier or p.team_id == carrier.team_id or p.is_goalkeeper:
				continue
			var to_carrier: Vector3 = carrier.global_position - p.global_position
			to_carrier.y = 0.0
			var gap: float = to_carrier.length()
			if gap > WATCH_RADIUS or gap < 0.01:
				continue
			_samples += 1
			var vel := Vector3(p.velocity.x, 0.0, p.velocity.z)
			var speed: float = vel.length()
			var approach: float = vel.normalized().dot(to_carrier / gap) if speed > 0.01 else 0.0
			var outside_poke: bool = not BallContest.within_poke_envelope(p, ball)

			_gaps.append(gap)
			_speeds.append(speed)
			_progress.append(p.challenge_progress)

			var ok_gap: bool = gap <= SlideTackle.SLIDE_START_RANGE
			var ok_speed: bool = speed >= SlideTackle.SLIDE_MIN_SPEED
			var ok_appr: bool = approach >= SlideTackle.SLIDE_MIN_APPROACH
			# The gate that WAS required and has since been removed, kept here
			# so re-running this tool still shows why: it is the reason the
			# original rule never fired.
			var ok_prog: bool = p.challenge_progress >= \
				BallContest.CHALLENGE_TIME_REQUIRED * 0.65
			if ok_gap: _pass_gap += 1
			if ok_speed: _pass_speed += 1
			if ok_appr: _pass_approach += 1
			if ok_prog: _pass_progress += 1
			if outside_poke: _pass_outside_poke += 1
			if ok_gap and ok_speed and ok_appr and ok_prog and outside_poke:
				_pass_all += 1

			# CANDIDATE rule, evaluated alongside so the change is chosen from
			# the distribution rather than by loosening numbers until slides
			# appear. It drops the accumulated-challenge requirement -- which
			# the data above shows is the binding constraint, and which is the
			# wrong idea anyway: a slide is a defender closing fast on a
			# carrier they cannot reach by pressing, not the culmination of a
			# long duel -- and pays for it with a much stricter lunge angle.
			if gap >= CAND_MIN_GAP and gap <= CAND_MAX_GAP \
				and speed >= CAND_MIN_SPEED and approach >= CAND_MIN_APPROACH \
				and outside_poke:
				_pass_candidate += 1

	_report()
	get_tree().quit()


func _report() -> void:
	print("SLIDEWIN: %d defender-frames within %.1fm of a carrier over %ds" % [
		_samples, WATCH_RADIUS, SECONDS])
	if _samples == 0:
		return
	_pct("gap <= %.1fm" % SlideTackle.SLIDE_START_RANGE, _pass_gap)
	_pct("speed >= %.1f m/s" % SlideTackle.SLIDE_MIN_SPEED, _pass_speed)
	_pct("approach >= %.2f" % SlideTackle.SLIDE_MIN_APPROACH, _pass_approach)
	_pct("progress >= %.2f (removed gate)" % (BallContest.CHALLENGE_TIME_REQUIRED * 0.65),
		_pass_progress)
	_pct("ball OUTSIDE poke reach", _pass_outside_poke)
	_pct("ALL AT ONCE (current)", _pass_all)
	_pct("CANDIDATE rule", _pass_candidate)
	# Per-player cooldown caps how many of those frames can become slides.
	print("SLIDEWIN:   candidate implies at most ~%.1f slides/min across the team" % [
		60.0 * (_pass_candidate / 60.0) / SlideTackle.SLIDE_COOLDOWN])
	_dist("gap", _gaps)
	_dist("speed", _speeds)
	_dist("progress", _progress)


func _pct(label: String, n: int) -> void:
	print("SLIDEWIN:   %-28s %6d (%5.1f%%)" % [label, n, 100.0 * n / _samples])


func _dist(label: String, values: Array) -> void:
	if values.is_empty():
		return
	values.sort()
	var n: int = values.size()
	print("SLIDEWIN:   %-8s median %.2f  p75 %.2f  p90 %.2f  max %.2f" % [
		label, values[n / 2], values[int(n * 0.75)], values[int(n * 0.9)], values[n - 1]])
