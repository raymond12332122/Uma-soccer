class_name FootballPerception
extends RefCounted

## What a footballer can actually see and infer, computed once and shared.
##
## Before this, every decision site worked out its own answer to the same
## handful of questions -- how pressured am I, how much space is there, can a
## pass survive that lane, where is the ball going to be. Those answers were
## scattered across AIController, TeamPlan and PassEvaluator, each with its own
## radius and its own weighting, and they disagreed with each other. That is
## why the bots "technically play football but do not understand it": they were
## not reasoning from a shared picture of the pitch.
##
## This is that shared picture. One snapshot per team per frame, built once and
## read by everything. It is deliberately NOT omniscient and deliberately NOT
## predictive beyond a short horizon -- see BALL_HORIZON for the bound.
##
## COST. A naive version of this is O(players^2) per player per frame, which at
## 22 players is 10k distance checks a frame before anything decides anything.
## Instead the expensive parts are computed ONCE for the whole team and the
## per-player queries read from that. See `_init()`.

## ---- Pressure ----
##
## An opponent is applying pressure from this far away, ramping to full at
## contact. Matches BallContest.CHALLENGE_RANGE, because "someone is pressing
## me" and "someone is contesting the ball" should mean the same thing to every
## part of the game.
const PRESSURE_RANGE := BallContest.CHALLENGE_RANGE
## Beyond this an opponent contributes nothing at all, so the sum stays local.
const PRESSURE_CUTOFF := 6.0
## A closing opponent presses harder than a stationary one at the same range.
## Bounded so a sprinter cannot manufacture unlimited pressure.
const PRESSURE_CLOSING_GAIN := 0.22
const PRESSURE_CLOSING_MAX := 0.45

## ---- Space ----
##
## Radius within which opponents deny space at a point. About the distance a
## defender can cover before a ball arrives from close range.
const SPACE_RADIUS := 5.0
## Space is also denied by being near the touchlines, because a player pinned
## against the line has half the options.
const TOUCHLINE_SOFT_MARGIN := 4.0

## ---- Lanes ----
##
## How far off a passing lane an opponent still threatens it. A defender is not
## a point: they can step across.
const LANE_HALF_WIDTH := 1.7
## An opponent nearer the passer than this is behind the ball and cannot
## intercept a pass that has already left.
const LANE_MIN_TRAVEL := 0.8

## ---- Anticipation ----
##
## How far ahead the ball's motion is projected. Deliberately short: this is a
## player reading a ball, not a physics oracle. Beyond about a second the ball
## has usually been touched by somebody and any prediction is fiction.
const BALL_HORIZON := 1.1
## Rolling resistance used for the projection. Matches the ball's linear damp
## closely enough for a one-second read.
const BALL_DAMP := 0.4

## ---- Danger ----
##
## Distance from our own goal inside which space is genuinely dangerous.
const DANGER_RADIUS := 22.0

## The team this snapshot belongs to.
var team_id: int = -1
var players: Array = []
var opponents: Array = []
var ball_pos := Vector3.ZERO
var ball_vel := Vector3.ZERO
var carrier: FootballPlayer = null
var carrier_is_ours: bool = false
var own_goal := Vector3.ZERO
var opponent_goal := Vector3.ZERO
var forward_axis := Vector3.RIGHT

## Where the ball will be in BALL_HORIZON seconds if nobody touches it, and how
## long until it is slow enough to be collected. See `_project_ball`.
var ball_future := Vector3.ZERO
var ball_settle_point := Vector3.ZERO
var ball_settle_time := 0.0

## The opponents' deepest outfield player along our forward axis -- the line a
## run in behind has to beat.
var opponent_last_line := 0.0
## Our own deepest outfield player: the top of our rest defence.
var own_last_line := 0.0

## instance_id -> pressure, precomputed for every player on both sides so a
## decision never has to sum opponents itself.
var _pressure := {}


## Build the snapshot. Construct once per team per frame.
##
## Everything that is O(players * opponents) happens here, exactly once, rather
## than inside each player's decision.
##
## Deliberately a constructor rather than a `static func build()` returning
## `FootballPerception.new()`. The static-factory form has to resolve its own
## class_name in order to construct itself, and on the FIRST load of a brand
## new class there is no such identifier yet: the script fails to compile, so
## it is never registered, so it never compiles. A constructor never names
## itself and cannot get into that state.
##
## (The global class cache is rebuilt by `godot --headless --import`, not by
## `--editor --quit`, which is worth knowing when a newly added class_name
## appears not to exist.)
func _init(p_team_id: int = -1, p_players: Array = [], p_opponents: Array = [],
		ball: RigidBody3D = null, possession: PossessionManager = null,
		p_own_goal: Vector3 = Vector3.ZERO, p_opponent_goal: Vector3 = Vector3.ZERO) -> void:
	team_id = p_team_id
	players = p_players
	opponents = p_opponents
	own_goal = p_own_goal
	opponent_goal = p_opponent_goal
	forward_axis = Vector3(signf(p_opponent_goal.x - p_own_goal.x), 0.0, 0.0)
	if forward_axis.x == 0.0:
		forward_axis = Vector3.RIGHT
	if ball != null and is_instance_valid(ball):
		ball_pos = ball.global_position
		ball_vel = ball.linear_velocity
	if possession != null:
		carrier = possession.current_carrier
		carrier_is_ours = carrier != null and carrier.team_id == p_team_id

	_project_ball()
	_compute_lines()
	_compute_pressure()


# ---------------------------------------------------------------------------
# Anticipation (brief section 6)
# ---------------------------------------------------------------------------

## Where a loose ball is heading, and when it becomes collectable.
##
## Bounded and physical: a damped projection of the ball's own velocity, capped
## at BALL_HORIZON. No player reads further ahead than this, which is what
## keeps "anticipation" from becoming "knows the future".
func _project_ball() -> void:
	var v := Vector3(ball_vel.x, 0.0, ball_vel.z)
	var p := Vector3(ball_pos.x, 0.0, ball_pos.z)
	if v.length() < 0.05:
		ball_future = p
		ball_settle_point = p
		ball_settle_time = 0.0
		return
	# Closed form of exponential damping over the horizon.
	var t: float = BALL_HORIZON
	var decay: float = exp(-BALL_DAMP * t)
	ball_future = p + v * (1.0 - decay) / BALL_DAMP
	# Time until the ball is slow enough that a player can take it cleanly.
	var target: float = FootballPlayer.CONTROLLED_BALL_SPEED * 0.6
	if v.length() <= target:
		ball_settle_time = 0.0
		ball_settle_point = p
	else:
		ball_settle_time = minf(log(v.length() / target) / BALL_DAMP, BALL_HORIZON)
		var d: float = exp(-BALL_DAMP * ball_settle_time)
		ball_settle_point = p + v * (1.0 - d) / BALL_DAMP


## Where a player should run to meet a loose ball, given how fast they move.
##
## Solves "when can I get there" against "where will it be then" by walking the
## projection forward, rather than running at where the ball is now -- which is
## what makes a whole team converge on a coordinate the ball has already left.
func intercept_point(from: Vector3, speed: float) -> Vector3:
	var v := Vector3(ball_vel.x, 0.0, ball_vel.z)
	var p := Vector3(ball_pos.x, 0.0, ball_pos.z)
	if v.length() < 0.05 or speed <= 0.01:
		return p
	var best: Vector3 = p
	var steps := 6
	for i in range(steps + 1):
		var t: float = BALL_HORIZON * float(i) / float(steps)
		var decay: float = exp(-BALL_DAMP * t)
		var at: Vector3 = p + v * (1.0 - decay) / BALL_DAMP
		best = at
		# The first point we could actually reach in time is the one to run at.
		if Vector3(from.x, 0.0, from.z).distance_to(at) <= speed * t:
			break
	return best


# ---------------------------------------------------------------------------
# Lines
# ---------------------------------------------------------------------------

## Both lines are held in FORWARD-AXIS space -- distance along our own
## direction of attack -- so the same arithmetic works for both teams without
## anyone having to remember which way they are kicking.
##
##   opponent_last_line  their deepest outfielder, i.e. the largest forward
##                       projection. A run in behind has to beat this.
##   own_last_line       our own deepest outfielder: the top of our rest
##                       defence, and the line a covering defender holds.
func _compute_lines() -> void:
	var fwd: float = forward_axis.x
	var deepest_opp: float = -INF
	var shallowest_own: float = INF
	for o in opponents:
		if o == null or not is_instance_valid(o) or o.is_goalkeeper:
			continue
		deepest_opp = maxf(deepest_opp, o.global_position.x * fwd)
	for p in players:
		if p == null or not is_instance_valid(p) or p.is_goalkeeper:
			continue
		shallowest_own = minf(shallowest_own, p.global_position.x * fwd)
	opponent_last_line = deepest_opp if deepest_opp != -INF else 0.0
	own_last_line = shallowest_own if shallowest_own != INF else 0.0


## Convert a forward-axis distance back into a world x. The inverse of the
## projection above, so callers can turn "three metres beyond their last line"
## into a place to run to.
func world_x(forward_distance: float) -> float:
	return forward_distance * forward_axis.x


# ---------------------------------------------------------------------------
# Pressure
# ---------------------------------------------------------------------------

func _compute_pressure() -> void:
	for p in players:
		if p != null and is_instance_valid(p):
			_pressure[p.get_instance_id()] = _pressure_at(p.global_position, opponents, p.velocity)
	for o in opponents:
		if o != null and is_instance_valid(o):
			_pressure[o.get_instance_id()] = _pressure_at(o.global_position, players, o.velocity)


## How pressured is this player, 0..1+? Precomputed; free to call.
func pressure_on(p: FootballPlayer) -> float:
	if p == null or not is_instance_valid(p):
		return 0.0
	return float(_pressure.get(p.get_instance_id(), 0.0))


## Pressure a hypothetical player at `pos` would be under. Used to score where
## a pass would put its receiver, which is not the same as where they are now.
func pressure_at(pos: Vector3) -> float:
	return _pressure_at(pos, opponents, Vector3.ZERO)


func _pressure_at(pos: Vector3, threats: Array, own_vel: Vector3) -> float:
	var total := 0.0
	var here := Vector3(pos.x, 0.0, pos.z)
	for t in threats:
		if t == null or not is_instance_valid(t) or t.is_goalkeeper:
			continue
		var there := Vector3(t.global_position.x, 0.0, t.global_position.z)
		var d: float = here.distance_to(there)
		if d > PRESSURE_CUTOFF:
			continue
		var near: float = clampf(1.0 - (d - BallContest.CONTACT_DISTANCE)
			/ maxf(PRESSURE_RANGE - BallContest.CONTACT_DISTANCE, 0.01), 0.0, 1.0)
		if near <= 0.0:
			continue
		# A defender travelling at you presses harder than one standing still.
		var closing := 0.0
		if d > 0.01:
			var rel := Vector3(t.velocity.x - own_vel.x, 0.0, t.velocity.z - own_vel.z)
			closing = clampf(rel.dot((here - there) / d) * PRESSURE_CLOSING_GAIN,
				0.0, PRESSURE_CLOSING_MAX)
		total += near + closing * near
	return total


# ---------------------------------------------------------------------------
# Space
# ---------------------------------------------------------------------------

## How open a point is, 0 (crowded or pinned to a line) .. 1 (clear grass).
##
## Counts opponents only. Teammates crowding a spot is a different problem --
## see `teammates_near`, which off-ball movement uses to avoid redundant runs.
func space_at(pos: Vector3, radius: float = SPACE_RADIUS) -> float:
	var here := Vector3(pos.x, 0.0, pos.z)
	var crowd := 0.0
	for o in opponents:
		if o == null or not is_instance_valid(o) or o.is_goalkeeper:
			continue
		var d: float = here.distance_to(Vector3(o.global_position.x, 0.0, o.global_position.z))
		if d < radius:
			crowd += 1.0 - d / radius
	var openness: float = clampf(1.0 - crowd * 0.55, 0.0, 1.0)
	# A player pinned against a touchline has fewer options than the raw
	# opponent count suggests.
	var half_w: float = FormationManager.FIELD_HALF_WIDTH
	var edge: float = clampf((half_w - absf(here.z)) / TOUCHLINE_SOFT_MARGIN, 0.0, 1.0)
	return openness * lerpf(0.65, 1.0, edge)


## How many of our own players are already within `radius` of a point. Off-ball
## movement uses this so two attackers do not make the same run.
func teammates_near(pos: Vector3, radius: float, except: FootballPlayer = null) -> int:
	var here := Vector3(pos.x, 0.0, pos.z)
	var n := 0
	for p in players:
		if p == null or not is_instance_valid(p) or p == except or p.is_goalkeeper:
			continue
		if here.distance_to(Vector3(p.global_position.x, 0.0, p.global_position.z)) < radius:
			n += 1
	return n


# ---------------------------------------------------------------------------
# Lanes
# ---------------------------------------------------------------------------

## Can a ball travel from `from` to `to` without an opponent stepping into it?
## 1.0 is a clean lane, 0.0 is blocked.
##
## Measured perpendicular to the lane, and only against opponents who are
## actually ahead of the ball -- one behind the passer cannot intercept
## something that has already gone past them.
func lane_quality(from: Vector3, to: Vector3) -> float:
	var a := Vector3(from.x, 0.0, from.z)
	var b := Vector3(to.x, 0.0, to.z)
	var span: Vector3 = b - a
	var length: float = span.length()
	if length < 0.01:
		return 1.0
	var dir: Vector3 = span / length
	var worst := 1.0
	for o in opponents:
		if o == null or not is_instance_valid(o):
			continue
		var rel: Vector3 = Vector3(o.global_position.x, 0.0, o.global_position.z) - a
		var along: float = rel.dot(dir)
		if along < LANE_MIN_TRAVEL or along > length:
			continue
		var off: float = (rel - dir * along).length()
		if off >= LANE_HALF_WIDTH:
			continue
		# Nearer the passer is more dangerous: the ball is slower to arrive
		# there in relative terms and the defender has more time.
		var severity: float = (1.0 - off / LANE_HALF_WIDTH)
		worst = minf(worst, 1.0 - severity)
	return clampf(worst, 0.0, 1.0)


# ---------------------------------------------------------------------------
# Threat and danger
# ---------------------------------------------------------------------------

## How dangerous is it for the OPPOSITION to have the ball at this point --
## used by defenders to decide what is worth protecting. 1.0 is our six-yard
## box, 0.0 is their half.
func danger_at(pos: Vector3) -> float:
	var d: float = Vector3(pos.x, 0.0, pos.z).distance_to(
		Vector3(own_goal.x, 0.0, own_goal.z))
	var near: float = clampf(1.0 - d / DANGER_RADIUS, 0.0, 1.0)
	# Central danger is worse than wide danger at the same distance.
	var half_w: float = FormationManager.FIELD_HALF_WIDTH
	var central: float = clampf(1.0 - absf(pos.z) / maxf(half_w, 0.01), 0.0, 1.0)
	return near * lerpf(0.55, 1.0, central)


## Is `pos` on the goal side of `threat` -- i.e. between them and our goal?
func is_goal_side(pos: Vector3, threat: Vector3) -> bool:
	var to_goal: Vector3 = Vector3(own_goal.x - threat.x, 0.0, own_goal.z - threat.z)
	if to_goal.length() < 0.01:
		return true
	return (Vector3(pos.x - threat.x, 0.0, pos.z - threat.z)).dot(to_goal.normalized()) > 0.0


## Progress toward the opponents' goal that moving from `a` to `b` represents,
## in metres. Negative is backwards.
func progression(a: Vector3, b: Vector3) -> float:
	return (b.x - a.x) * forward_axis.x
