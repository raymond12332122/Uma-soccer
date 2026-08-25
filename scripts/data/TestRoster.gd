class_name TestRoster
extends RefCounted

## Small hand-built test squads for the V0.3 3v3(+GK) match. Not the real
## Uma roster -- just enough varied data to prove PlayerData actually
## drives gameplay differences between characters.

static func home_team() -> Array[PlayerData]:
	var roster: Array[PlayerData] = [
		_make("home_gk", "Yuki", "GK", 4.2, 12.0, 6.0, 55, 40, 50, 70, 75, "Right"),
		_make("home_def", "Haru", "DEF", 4.8, 13.0, 7.8, 68, 55, 60, 78, 80, "Right"),
		_make("home_mid", "Sora", "MID", 5.2, 14.5, 8.6, 78, 68, 75, 82, 62, "Right"),
		_make("home_fwd", "Rin", "FWD", 5.6, 15.5, 9.2, 65, 85, 80, 75, 45, "Left"),
	]
	# First integrated character model (v0.4) -- the default human-controlled
	# player, so its payoff is visible immediately without needing to switch.
	roster[2].visual_id = "tokai_teio"
	return roster


static func away_team() -> Array[PlayerData]:
	return [
		_make("away_gk", "Kaito", "GK", 4.1, 12.0, 5.9, 52, 38, 48, 68, 74, "Right"),
		_make("away_def", "Ren", "DEF", 4.7, 12.8, 7.6, 66, 52, 58, 76, 82, "Right"),
		_make("away_mid", "Aoi", "MID", 5.1, 14.2, 8.4, 80, 65, 72, 80, 60, "Left"),
		_make("away_fwd", "Sho", "FWD", 5.7, 15.8, 9.4, 62, 84, 78, 72, 42, "Right"),
	]


static func _make(
	id: String, display_name: String, position: String,
	speed: float, accel: float, sprint: float,
	pass_stat: float, shoot_stat: float, dribble_stat: float,
	stamina: float, defense: float, foot: String
) -> PlayerData:
	var data := PlayerData.new()
	data.id = id
	data.display_name = display_name
	data.position = position
	data.movement_speed = speed
	data.acceleration = accel
	data.sprint_speed = sprint
	data.passing = pass_stat
	data.shooting = shoot_stat
	data.dribbling = dribble_stat
	data.stamina = stamina
	data.defensive_ability = defense
	data.preferred_foot = foot
	return data
