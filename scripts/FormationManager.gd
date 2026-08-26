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

const FIELD_HALF_LENGTH := 26.0
const FIELD_HALF_WIDTH := 17.0

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
