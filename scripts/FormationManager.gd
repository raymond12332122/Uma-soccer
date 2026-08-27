class_name FormationManager
extends RefCounted

## Data-driven formations. Each formation is an ordered Array of slot
## dictionaries: {"role": <specific slot code>, "pos": Vector2}. Order
## matters -- MatchManager spawns roster[i] into slots[i], and slot 0 is
## always the goalkeeper by convention (matching PlayerData/TestRoster
## ordering). "pos" is a normalized team-local coordinate:
##   x: -1 (own goal line) .. 0 (halfway line) .. 1 (opponent goal line)
##   y: -1 (touchline A)   .. 0 (center)        .. 1 (touchline B)
## get_world_position() scales/mirrors these per team, so the same slot
## data produces a sensible layout for either side.
##
## Adding "4-4-2", "3-5-2", "4-2-3-1", etc. later is just adding another
## entry to FORMATIONS -- TeamController and AIController both already
## work generically off role_category() rather than a specific formation
## name or slot count, so nothing there needs to change.

## The FORMATION field -- the box formation slots are laid out inside. This
## is deliberately smaller than the pitch the players can physically stand
## on, so a 4-3-3 drawn at ±1.0 still sits comfortably inside the touchlines.
const FIELD_HALF_LENGTH := 26.0
const FIELD_HALF_WIDTH := 17.0

## v0.8.6: the REAL geometry the match is actually played in, read straight
## off scenes/Field.tscn. Before this existed there was no model of the
## pitch anywhere -- FIELD_HALF_LENGTH/WIDTH were a formation-layout box
## that positioning code then reused as if it were the playing area, and
## the two do not line up with the built stadium at all:
##
##   goal mouth (posts)   x = ±29.0,  z = ±4.0
##   net back             x = ±32.2
##   perimeter walls      x = ±35.0,  z = ±23.0
##
## So "the goal" that every attacking decision aimed at (x = ±26) was a
## point 3m IN FRONT of the actual goal line, and the strip from x=29 out to
## the wall at x=35 -- the whole area behind each goal -- was somewhere the
## code had no opinion about whatsoever. That is the root of the reported
## "an opponent moved behind the goal and tried to score from there": there
## was no such thing as being behind the goal as far as the AI was concerned.
const GOAL_LINE_X := 29.0
## Half the distance between the posts (they sit at z = ±4.0 and are 0.3
## wide, so the clear opening is a shade under 4). Aim points are kept
## inside this so a shot goes between the posts rather than at one.
const GOAL_HALF_WIDTH := 3.4

## The area a player is allowed to have a movement target inside. Stops a
## metre short of the goal line, so an AI player's aim point can never be
## level with or behind the goal -- they play up to the line and no further,
## which is what a footballer does.
const PLAYABLE_HALF_LENGTH := GOAL_LINE_X - 1.0
## Comfortably inside the perimeter walls at ±23, and outside the formation
## box at ±17 so wide players can still genuinely hug a touchline.
const PLAYABLE_HALF_WIDTH := 21.0

const FORMATIONS := {
	"4_3_3": [
		{"role": "GK", "pos": Vector2(-0.94, 0.0)},
		{"role": "LB", "pos": Vector2(-0.55, -0.62)},
		{"role": "CB", "pos": Vector2(-0.68, -0.20)},
		{"role": "CB", "pos": Vector2(-0.68, 0.20)},
		{"role": "RB", "pos": Vector2(-0.55, 0.62)},
		{"role": "CM", "pos": Vector2(-0.08, -0.34)},
		{"role": "CM", "pos": Vector2(-0.16, 0.0)},
		{"role": "CM", "pos": Vector2(-0.08, 0.34)},
		{"role": "LW", "pos": Vector2(0.42, -0.70)},
		{"role": "ST", "pos": Vector2(0.55, 0.0)},
		{"role": "RW", "pos": Vector2(0.42, 0.70)},
	],
}

const DEFAULT_FORMATION := "4_3_3"

## Specific slot role -> broad category. AIController reads this for
## generic (never character-specific) positional behavior: how far to
## advance when attacking, how hard to recover when defending, etc. New
## formations can introduce new specific role codes as long as they're
## added here too; unrecognized codes fall back to "MID" (a reasonable
## neutral default) rather than crashing.
const ROLE_CATEGORY := {
	"GK": "GK",
	"LB": "DEF", "CB": "DEF", "RB": "DEF",
	"CM": "MID",
	"LW": "FWD", "ST": "FWD", "RW": "FWD",
}


static func get_slots(formation_name: String) -> Array:
	return FORMATIONS.get(formation_name, FORMATIONS[DEFAULT_FORMATION])


static func role_category(role: String) -> String:
	return ROLE_CATEGORY.get(role, "MID")


## Centre of the goal a team attacking along `forward_axis` is shooting at,
## on the REAL goal line rather than the nominal formation point 3m in front
## of it. Takes the axis rather than a team id so every caller that already
## has a TeamPlan can use it without threading an extra argument through.
static func attacking_goal_mouth(forward_axis: Vector3) -> Vector3:
	var side: float = signf(forward_axis.x) if forward_axis.x != 0.0 else 1.0
	return Vector3(side * GOAL_LINE_X, 0.0, 0.0)


## The goal a team attacking along `forward_axis` is defending.
static func defending_goal_mouth(forward_axis: Vector3) -> Vector3:
	return attacking_goal_mouth(-forward_axis)


## Where inside the goal mouth to actually strike the ball, given where the
## shot is being taken from and who is in the way.
##
## Aiming at the exact centre of the goal means aiming at the goalkeeper,
## who stands there by definition. This picks the half of the mouth the
## keeper is NOT covering and aims just inside the post on that side, which
## is both a better chance and legibly a *placed* shot rather than a hoof at
## the middle. Falls back to the far side relative to the shooter when there
## is no keeper to read.
static func goal_aim_point(forward_axis: Vector3, from_pos: Vector3, keeper_pos: Vector3 = Vector3.INF) -> Vector3:
	var mouth: Vector3 = attacking_goal_mouth(forward_axis)
	# Just inside the post -- never AT it.
	var inset: float = GOAL_HALF_WIDTH * 0.7
	var side: float
	if keeper_pos != Vector3.INF:
		# Away from wherever the keeper is standing.
		side = -signf(keeper_pos.z) if absf(keeper_pos.z) > 0.15 else -signf(from_pos.z)
	else:
		side = -signf(from_pos.z)
	if side == 0.0:
		side = 1.0
	mouth.z = side * inset
	mouth.y = from_pos.y
	return mouth


## True when `pos` is beyond the deepest point of the field of play --
## level with or behind a goal. Players should never be *targeted* here.
##
## The comparison is strict against PLAYABLE_HALF_LENGTH so that a target
## which clamp_to_playable() has just pulled back TO the limit is legal:
## playing right up to the byline is football, being behind the net is not.
static func is_behind_goal_line(pos: Vector3) -> bool:
	return absf(pos.x) > PLAYABLE_HALF_LENGTH


## Confines a movement target to the area football is actually played in.
## This is the single place the playable area is enforced, and it is applied
## to a TARGET, never to a player's position -- a player who has carried
## their own momentum past the line walks back in of their own accord rather
## than being teleported, which is the difference between a rule and a
## band-aid.
static func clamp_to_playable(pos: Vector3) -> Vector3:
	return Vector3(
		clampf(pos.x, -PLAYABLE_HALF_LENGTH, PLAYABLE_HALF_LENGTH),
		pos.y,
		clampf(pos.z, -PLAYABLE_HALF_WIDTH, PLAYABLE_HALF_WIDTH))


## team_id 0 (home) attacks +X, defends -X (own goal near -X).
## team_id 1 (away) is mirrored: attacks -X, defends +X.
static func get_world_position(normalized: Vector2, team_id: int, field_half_length: float = FIELD_HALF_LENGTH, field_half_width: float = FIELD_HALF_WIDTH) -> Vector3:
	var side := 1.0 if team_id == 0 else -1.0
	var x := normalized.x * field_half_length * side
	var z := normalized.y * field_half_width
	return Vector3(x, 1.0, z)


## Role-category shift weights for get_dynamic_position -- how much a
## player's formation target reacts to the ball's current location.
## Generic (role-based only, never character-specific): defenders barely
## shift longitudinally (hold depth) but do compress laterally to stay
## compact; forwards/midfielders push further with the ball both ways.
const _DYNAMIC_LONGITUDINAL_MULT := {"GK": 0.0, "DEF": 0.12, "MID": 0.22, "FWD": 0.30}
const _DYNAMIC_LATERAL_MULT := {"GK": 0.0, "DEF": 0.35, "MID": 0.55, "FWD": 0.45}

## Same as get_world_position, but the resulting spot continuously shifts
## with the ball's current position instead of sitting at a permanently
## fixed coordinate. This is what makes team shape look alive: a static
## formation_target only ever changes across a goal/restart, so a player
## whose slot happens to be far from wherever play currently is just sits
## motionless at that exact spot indefinitely -- the actual root cause of
## "some players barely move or do not move at all". Shifting the base
## target itself (rather than only the attacking-support "advance" vector)
## means the fallback-defensive branch benefits too, since it derives its
## target from this same value.
static func get_dynamic_position(normalized: Vector2, team_id: int, ball_pos: Vector3, category: String, field_half_length: float = FIELD_HALF_LENGTH, field_half_width: float = FIELD_HALF_WIDTH) -> Vector3:
	var base: Vector3 = get_world_position(normalized, team_id, field_half_length, field_half_width)
	var side := 1.0 if team_id == 0 else -1.0

	# -1 (ball deep in our own half) .. +1 (ball deep in the opponent half).
	var ball_progress: float = clampf((ball_pos.x * side) / field_half_length, -1.0, 1.0)
	# -1 (ball on the near touchline) .. +1 (ball on the far touchline).
	var ball_lateral: float = clampf(ball_pos.z / field_half_width, -1.0, 1.0)

	var longitudinal_mult: float = _DYNAMIC_LONGITUDINAL_MULT.get(category, 0.2)
	var lateral_mult: float = _DYNAMIC_LATERAL_MULT.get(category, 0.4)

	var shift_x: float = ball_progress * field_half_length * longitudinal_mult * side
	var shift_z: float = ball_lateral * field_half_width * lateral_mult

	var result: Vector3 = base + Vector3(shift_x, 0.0, shift_z)
	result.x = clampf(result.x, -field_half_length - 4.0, field_half_length + 4.0)
	result.z = clampf(result.z, -field_half_width - 2.0, field_half_width + 2.0)
	return result
