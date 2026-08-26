class_name AIController
extends RefCounted

## Simple, stateless per-frame decision logic for AI-controlled players.
## TeamController calls these each physics frame for every player on its
## roster that isn't the current human target (and, since v0.6, that
## doesn't have an active personality event driving it -- see
## PersonalityEventSystem). No memory/planning between frames on purpose --
## this is foundation-level AI, not tactics.
##
## Decision hierarchy per non-carrier player, in priority order:
##   1. immediate danger / 2. possession opportunity -- the team's single
##      nominated ball_challenger (nearest suitable teammate, computed once
##      per team per frame by TeamController -- see find_ball_challenger)
##      goes straight at the ball, whether it's loose or an opponent has it
##      (the ball's own position already tracks the carrier via the
##      dribble-steering force, so "press the carrier" and "chase the loose
##      ball" collapse into the same target).
##   3. defensive responsibility -- everyone else recovers toward
##      defensive shape, pulled harder for defenders, moderately for
##      midfielders, lightly for forwards (limited defensive support),
##      with a slight bias toward covering the most advanced opponent
##      (dangerous_opponent, also computed once per team per frame).
##   4. attacking opportunity / 5. formation positioning -- when the ball
##      carrier is a teammate, everyone else pushes into useful space
##      ahead of their formation slot (see _advance_distance) while
##      holding spacing from each other.
##
## Formation role (player.formation_role, via FormationManager.role_category)
## is a generic GK/DEF/MID/FWD bucket -- never a specific character -- so
## "defenders hold depth, wingers stretch wide, strikers push higher" comes
## from the role a character is currently playing, not who they are.
##
## Personality (player.personality) continuously modifies these decisions
## on top of role/stats via generic formulas reading trait values -- no
## per-character branches here. A disciplined/tactically-aware character
## holds tighter formation and marks tighter; a high-aggression/risk-taking
## character makes bigger forward runs, sprints more readily, and shoots
## from further out; better teamwork keeps tighter spacing. Every
## character's data alone accounts for the behavioral differences.

const SHOOT_RANGE := 9.0
const SPACING_RADIUS := 6.0
const ARRIVE_RADIUS := 0.6
const SPRINT_DISTANCE := 8.0

const GK_LATERAL_RANGE := 3.5
const GK_FORWARD_RANGE := 2.5
const GK_DANGER_DISTANCE := 7.0
const GK_ARRIVE_RADIUS := 0.25

## Minimum distance a supporting (non-carrier) attacking teammate's target
## is allowed to end up from the ball/carrier -- keeps support runs
## spreading into passing lanes around the carrier instead of converging
## on top of them, which read as "AI just follows me" at close range.
## Applies equally to a human or AI carrier; nothing here is aware of
## which one it is.
const MIN_SUPPORT_DISTANCE_FROM_BALL := 3.2

## An opponent closer than this to the ball carrier counts as real
## pressure -- pushes the release-the-ball decision below instead of
## holding it indefinitely. Roughly a lunging-tackle distance.
const PRESSURE_DISTANCE := 3.0

## Formation-role-category multipliers -- generic positional tendencies,
## not character-specific. Forwards make the biggest attacking runs and
## give the least defensive recovery ("limited defensive support");
## defenders are the mirror image (hold depth attacking, recover hardest
## defending); midfielders sit in between ("track dangerous areas" /
## "provide passing options").
const ROLE_ATTACK_MULT := {"GK": 0.0, "DEF": 0.45, "MID": 0.85, "FWD": 1.25}
const ROLE_DEFENSE_MULT := {"GK": 0.0, "DEF": 1.25, "MID": 0.9, "FWD": 0.55}
const WINGER_WIDTH_STRETCH := 1.15

## Below this stamina ratio, positioning gets a small amount of random
## noise -- fatigue affecting "decision quality slightly" per the brief,
## without ever disabling the player (still moves, still presses, still
## defends; just a little less precise).
const FATIGUE_DECISION_THRESHOLD := 0.3
const FATIGUE_NOISE_SCALE := 1.5


static func update_player(
	player: FootballPlayer,
	ball: RigidBody3D,
	possession: PossessionManager,
	teammates: Array,
	opponents: Array,
	own_goal_pos: Vector3,
	opponent_goal_pos: Vector3,
	formation_target: Vector3,
	ball_challenger: FootballPlayer = null,
	dangerous_opponent: Node3D = null,
	delta: float = 1.0 / 60.0
) -> void:
	var attacking: bool = possession.possessing_team == player.team_id
	var category: String = FormationManager.role_category(player.formation_role)
	var target: Vector3

	if attacking and player.has_possession:
		# I have the ball -- carry it toward goal by default, but run a
		# real decision hierarchy first: shoot / forward pass / release
		# under pressure / safe pass, falling back to carrying only when
		# none of those actually apply this frame (see
		# _decide_possession_action). Carrying toward goal is still the
		# steering target regardless -- a pass/shot call below releases
		# the ball immediately (has_possession goes false), so there's no
		# risk of also acting on a now-stale target this same frame.
		target = opponent_goal_pos
		_decide_possession_action(player, opponent_goal_pos, own_goal_pos, opponents, delta)
	elif attacking:
		# Support: push into useful space ahead of the formation slot,
		# scaled by role (forwards make the biggest runs, defenders mostly
		# hold depth) and by aggression/risk-taking/teamwork as before.
		# Wingers additionally stay wide to stretch the field rather than
		# drifting in toward the ball/center.
		var advance_distance: float = _advance_distance(player) * ROLE_ATTACK_MULT.get(category, 1.0)
		# Pure attack-axis direction rather than "straight at the goal
		# mouth" -- the latter makes every role's advance vector
		# converge toward the same central point as it lengthens, which
		# is what made support runs look like they were all collapsing
		# in on the ball/carrier. Each role keeps its own lane; lateral
		# variety comes from formation_target itself (already
		# ball-reactive -- see FormationManager.get_dynamic_position).
		var advance: Vector3 = Vector3(signf(opponent_goal_pos.x - own_goal_pos.x), 0.0, 0.0) * advance_distance
		target = formation_target + advance + _spacing_offset(player, teammates)
		if player.formation_role == "LW" or player.formation_role == "RW":
			target.z = formation_target.z * WINGER_WIDTH_STRETCH
		target = _keep_support_distance(target, ball.global_position)
	else:
		# Opponent has it, or the ball is loose: the team's nominated
		# ball_challenger presses the ball directly; everyone else holds a
		# defensive-leaning shape, pulled back by role + discipline, with a
		# slight bias toward covering the most advanced opponent.
		if player == ball_challenger:
			target = ball.global_position
		else:
			var fallback_pull: float = clampf(lerp(0.1, 0.4, player.personality.discipline / 100.0) * ROLE_DEFENSE_MULT.get(category, 1.0), 0.0, 0.85)
			target = formation_target.lerp(own_goal_pos, fallback_pull)
			if dangerous_opponent:
				target = target.lerp(dangerous_opponent.global_position, 0.12 * ROLE_DEFENSE_MULT.get(category, 1.0))

	target += _fatigue_noise(player)

	_move_toward(player, target, ARRIVE_RADIUS)
	player.sprint_requested = player.global_position.distance_to(target) > _sprint_threshold(player)


## v0.8.1: the actual decision hierarchy for an AI player currently in
## possession -- before this existed, update_player()'s attacking branch
## only ever checked "am I in shooting range," so an AI player who never
## got that close simply carried the ball forever; nothing here ever
## called execute_pass() for an AI player at all. Evaluated in priority
## order, self-limiting by construction: execute_shot()/execute_pass()
## both clear has_possession immediately, so once either fires this
## player exits the "attacking and has_possession" branch entirely on the
## very next frame -- there is no separate re-entrancy guard needed.
##
## Both shoot and pass are gated by a per-second *rate* (scaled by delta,
## not a flat per-frame probability) so the eventual decision is
## frame-rate independent and, for a genuinely good chance, fires within
## roughly a second or two rather than instantly on the very first
## qualifying frame or never at all -- it reads as "decided", not as
## "rolled a die every tick". Stats (shooting/passing) and personality
## (confidence/risk_taking/competitiveness for shooting; tactical_awareness/
## teamwork for passing) bias the rate per player, so different characters
## genuinely behave differently -- never a hard-coded per-character branch.
static func _decide_possession_action(player: FootballPlayer, opponent_goal_pos: Vector3, own_goal_pos: Vector3, opponents: Array, delta: float) -> void:
	var p: PersonalityData = player.personality
	var stats: PlayerData = player.player_data

	# 1. Immediate shooting opportunity.
	var shoot_range: float = _shoot_range(player)
	var dist_to_goal: float = player.global_position.distance_to(opponent_goal_pos)
	if dist_to_goal < shoot_range:
		var shoot_skill: float = stats.shooting if stats else 50.0
		var shoot_eagerness: float = (p.confidence + p.risk_taking + p.competitiveness) / 3.0
		var shoot_rate: float = lerp(1.5, 5.0, clampf((shoot_eagerness + shoot_skill) / 200.0, 0.0, 1.0))
		if randf() < shoot_rate * delta:
			player.execute_shot(clampf(1.0 - dist_to_goal / shoot_range, 0.35, 1.0))
			return

	# 2/3/4. Forward/valuable pass, or -- under real pressure -- any safe
	# release rather than continuing to hold the ball. _find_pass_target
	# already scores candidates by alignment/distance/lane/openness/role
	# (see FootballPlayer.gd) and already considers every teammate,
	# including whichever one is currently human-controlled -- there is
	# nothing here that treats the human differently from any other
	# teammate.
	var pass_target: FootballPlayer = player._find_pass_target(player._get_aim_direction())
	if pass_target != null:
		var nearest_opp: float = _nearest_opponent_distance(player, opponents)
		var under_pressure: bool = nearest_opp < PRESSURE_DISTANCE

		var pass_skill: float = stats.passing if stats else 50.0
		var pass_will: float = (p.tactical_awareness + p.teamwork) / 2.0
		var pass_rate: float = lerp(0.6, 3.0, clampf((pass_will + pass_skill) / 200.0, 0.0, 1.0))
		if under_pressure:
			pass_rate *= 3.5  # a closing defender should force a much quicker decision
		if randf() < pass_rate * delta:
			player.execute_pass()
			return

	# 5. Fallback: keep dribbling/carrying -- update_player()'s caller
	# already left `target` pointed at goal, nothing further to do here.


static func _nearest_opponent_distance(player: FootballPlayer, opponents: Array) -> float:
	var best := INF
	for opp in opponents:
		if opp == null or not is_instance_valid(opp):
			continue
		var d: float = player.global_position.distance_to(opp.global_position)
		if d < best:
			best = d
	return best


static func update_goalkeeper(player: FootballPlayer, ball: RigidBody3D, own_goal_pos: Vector3) -> void:
	if player.has_possession:
		# Don't dribble around the box -- clear it upfield immediately.
		player.execute_shot(0.5)
		player.move_input = Vector2.ZERO
		player.sprint_requested = false
		return

	var center_dir_x: float = -signf(own_goal_pos.x) if own_goal_pos.x != 0.0 else 1.0

	var target := own_goal_pos
	target.z = clampf(ball.global_position.z, own_goal_pos.z - GK_LATERAL_RANGE, own_goal_pos.z + GK_LATERAL_RANGE)

	var dist_to_ball_x: float = absf(ball.global_position.x - own_goal_pos.x)
	if dist_to_ball_x < GK_DANGER_DISTANCE:
		var step: float = clampf(GK_DANGER_DISTANCE - dist_to_ball_x, 0.0, GK_FORWARD_RANGE)
		target.x = own_goal_pos.x + center_dir_x * step

	_move_toward(player, target, GK_ARRIVE_RADIUS)
	player.sprint_requested = dist_to_ball_x < GK_DANGER_DISTANCE


## Nearest suitable teammate to the ball -- the single player who presses/
## challenges for it this frame (see the decision-hierarchy note above).
## Computed once per team per frame by TeamController rather than
## redundantly inside every single player's update, which used to be an
## O(team_size * opponents) waste repeated once per non-marking player;
## now it's O(team_size) once.
static func find_ball_challenger(teammates: Array, ball: RigidBody3D) -> FootballPlayer:
	return _closest_to(teammates, ball.global_position)


## The most advanced opponent (closest to our own goal) -- a cheap proxy
## for "who's making the dangerous run," used to bias non-challenging
## defenders' fallback shape toward covering them. Also computed once per
## team per frame by TeamController, for the same reason as
## find_ball_challenger above.
static func find_dangerous_opponent(opponents: Array, own_goal_pos: Vector3) -> Node3D:
	var best: Node3D = null
	var best_dist := INF
	for opp in opponents:
		if opp.is_goalkeeper:
			continue
		var d: float = opp.global_position.distance_to(own_goal_pos)
		if d < best_dist:
			best_dist = d
			best = opp
	return best


## Pushes a support target outward if it ends up closer than
## MIN_SUPPORT_DISTANCE_FROM_BALL to the ball -- keeps supporting
## teammates spread into open passing lanes around the carrier instead of
## converging on top of them (see the const doc comment above).
static func _keep_support_distance(target: Vector3, ball_pos: Vector3) -> Vector3:
	var diff := Vector2(target.x, target.z) - Vector2(ball_pos.x, ball_pos.z)
	var dist := diff.length()
	if dist >= MIN_SUPPORT_DISTANCE_FROM_BALL or dist < 0.001:
		return target
	var pushed: Vector2 = diff.normalized() * MIN_SUPPORT_DISTANCE_FROM_BALL
	return Vector3(ball_pos.x + pushed.x, target.y, ball_pos.z + pushed.y)


static func _move_toward(player: FootballPlayer, target: Vector3, arrive_radius: float) -> void:
	var to_target: Vector3 = target - player.global_position
	to_target.y = 0.0
	if to_target.length() > arrive_radius:
		player.move_input = Vector2(to_target.x, to_target.z).limit_length(1.0)
	else:
		player.move_input = Vector2.ZERO


static func _spacing_offset(player: FootballPlayer, teammates: Array) -> Vector3:
	var spacing_radius: float = lerp(4.0, 8.0, player.personality.teamwork / 100.0)
	var offset := Vector3.ZERO
	for mate in teammates:
		if mate == player or mate.is_goalkeeper:
			continue
		var diff: Vector3 = player.global_position - mate.global_position
		var dist := diff.length()
		if dist < spacing_radius and dist > 0.01:
			offset += diff.normalized() * (spacing_radius - dist) * 0.5
	return offset


## Higher aggression/risk-taking/impulsiveness -> bigger forward runs when
## supporting an attack; higher discipline pulls that back in slightly so
## a disciplined-but-aggressive character doesn't fully abandon shape.
static func _advance_distance(player: FootballPlayer) -> float:
	var p: PersonalityData = player.personality
	var eagerness: float = (p.aggression + p.risk_taking) / 2.0
	var distance: float = lerp(3.0, 9.0, eagerness / 100.0)
	distance -= (p.discipline - 50.0) * 0.02
	return clampf(distance, 2.0, 10.0)


## Higher aggression/risk-taking/impulsiveness -> sprints from further
## away (more eager); higher stamina_management/composure -> waits until
## closer (doesn't waste energy / stays composed).
static func _sprint_threshold(player: FootballPlayer) -> float:
	var p: PersonalityData = player.personality
	var eagerness: float = (p.aggression + p.risk_taking + p.impulsiveness) / 3.0
	var restraint: float = (p.stamina_management + p.composure) / 2.0
	var threshold: float = SPRINT_DISTANCE - (eagerness - 50.0) * 0.06 + (restraint - 50.0) * 0.04
	return clampf(threshold, 4.0, 14.0)


## Higher confidence/risk-taking -> willing to shoot from further out.
static func _shoot_range(player: FootballPlayer) -> float:
	var p: PersonalityData = player.personality
	var boldness: float = (p.confidence + p.risk_taking) / 2.0
	var range_val: float = SHOOT_RANGE + (boldness - 50.0) * 0.1
	return clampf(range_val, 6.0, 14.0)


## Small positional imprecision once a player is significantly fatigued --
## "decision quality slightly" affected by stamina, never enough to stop
## them moving/pressing/defending normally.
static func _fatigue_noise(player: FootballPlayer) -> Vector3:
	var stamina_ratio: float = (player.current_stamina / player.max_stamina) if player.max_stamina > 0.0 else 1.0
	if stamina_ratio >= FATIGUE_DECISION_THRESHOLD:
		return Vector3.ZERO
	var magnitude: float = (FATIGUE_DECISION_THRESHOLD - stamina_ratio) * FATIGUE_NOISE_SCALE
	return Vector3(randf_range(-magnitude, magnitude), 0.0, randf_range(-magnitude, magnitude))


static func _closest_to(players: Array, pos: Vector3) -> FootballPlayer:
	var best: FootballPlayer = null
	var best_dist := INF
	for p in players:
		if p.is_goalkeeper:
			continue
		var d: float = p.global_position.distance_to(pos)
		if d < best_dist:
			best_dist = d
			best = p
	return best


static func _safe_normalize(v: Vector3) -> Vector3:
	if v.length() < 0.001:
		return Vector3.FORWARD
	return v.normalized()
