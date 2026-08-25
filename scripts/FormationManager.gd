class_name FormationManager
extends RefCounted

## Data-driven starting positions. Slots are normalized team-local
## coordinates:
##   x: -1 (own goal line) .. 0 (halfway line) .. 1 (opponent goal line)
##   z: -1 (touchline A)   .. 0 (center)        .. 1 (touchline B)
## get_world_position() scales them to the actual field and mirrors them
## per team, so the same slot data produces a sensible layout for either
## side. Adding "4-3-3", "4-4-2", etc. later is just adding more entries
## here -- nothing else needs to change.

const FIELD_HALF_LENGTH := 26.0
const FIELD_HALF_WIDTH := 17.0

const FORMATIONS := {
	"3_flat": {
		"GK": [Vector2(-0.94, 0.0)],
		"OUT": [
			Vector2(-0.45, 0.0),
			Vector2(-0.05, -0.35),
			Vector2(0.35, 0.35),
		],
	},
}


static func get_slots(formation_name: String) -> Dictionary:
	return FORMATIONS.get(formation_name, FORMATIONS["3_flat"])


## team_id 0 (home) attacks +X, defends -X (own goal near -X).
## team_id 1 (away) is mirrored: attacks -X, defends +X.
static func get_world_position(normalized: Vector2, team_id: int, field_half_length: float = FIELD_HALF_LENGTH, field_half_width: float = FIELD_HALF_WIDTH) -> Vector3:
	var side := 1.0 if team_id == 0 else -1.0
	var x := normalized.x * field_half_length * side
	var z := normalized.y * field_half_width
	return Vector3(x, 1.0, z)
