class_name TestRoster
extends RefCounted

## Full 11v11 test squads for the v0.7 4-3-3 match. Not the real Uma
## roster -- reuses the 11 currently-integrated character models across
## both teams (22 player slots, 11 unique characters x 2), each built as
## its own independent PlayerData/FootballPlayer instance so two on-pitch
## copies of the same character never share state (stats, stamina,
## personality event cooldowns, etc. all live per-instance). See
## assets/characters/CREDITS.md for the models themselves.
##
## A character's football-ability stats (CHARACTER_BASE_STATS) are the
## same regardless of which team or formation slot they're placed in --
## only PersonalityData (a separate axis, see PersonalityProfiles, looked
## up by visual_id exactly the same way here) and the formation-driven AI
## behavior around them differ.

## visual_id -> [speed, accel, sprint, passing, shooting, dribbling, stamina, defense, foot]
const CHARACTER_BASE_STATS := {
	"tokai_teio":     [5.6, 15.0, 9.4, 74.0, 82.0, 80.0, 78.0, 55.0, "Right"],
	"agnes_digital":  [5.2, 14.0, 8.6, 72.0, 68.0, 74.0, 82.0, 58.0, "Right"],
	"tamamo_cross":   [5.3, 14.6, 8.8, 68.0, 74.0, 78.0, 76.0, 66.0, "Left"],
	"oguri_cap":      [5.5, 15.2, 9.0, 66.0, 80.0, 76.0, 74.0, 60.0, "Left"],
	"gold_ship":      [5.0, 13.5, 8.3, 58.0, 62.0, 72.0, 68.0, 58.0, "Right"],
	"symboli_rudolf": [4.7, 12.8, 7.6, 76.0, 52.0, 58.0, 80.0, 82.0, "Right"],
	"air_groove":     [4.9, 13.2, 7.9, 74.0, 55.0, 62.0, 82.0, 84.0, "Right"],
	"tm_opera_o":     [5.4, 14.8, 8.9, 70.0, 84.0, 80.0, 72.0, 50.0, "Right"],
	"grass_wonder":   [5.1, 13.8, 8.2, 80.0, 65.0, 70.0, 78.0, 62.0, "Left"],
	"mejiro_mcqueen": [5.0, 13.6, 8.0, 75.0, 63.0, 68.0, 80.0, 66.0, "Right"],
	"silence_suzuka": [5.9, 15.6, 9.6, 62.0, 70.0, 74.0, 70.0, 48.0, "Left"],
}

const DISPLAY_NAMES := {
	"tokai_teio": "Teio", "agnes_digital": "Agnes", "tamamo_cross": "Tamamo",
	"oguri_cap": "Oguri", "gold_ship": "Gold", "symboli_rudolf": "Rudolf",
	"air_groove": "Groove", "tm_opera_o": "Opera", "grass_wonder": "Grass",
	"mejiro_mcqueen": "McQueen", "silence_suzuka": "Suzuka",
}

## Order matches FormationManager.get_slots("4_3_3"): GK, LB, CB, CB, RB,
## CM, CM, CM, LW, ST, RW. Every one of the 11 registered characters
## appears exactly once per team.
const HOME_ORDER := [
	"air_groove", "gold_ship", "symboli_rudolf", "mejiro_mcqueen", "oguri_cap",
	"grass_wonder", "tamamo_cross", "agnes_digital",
	"silence_suzuka", "tokai_teio", "tm_opera_o",
]
const AWAY_ORDER := [
	"symboli_rudolf", "tamamo_cross", "air_groove", "grass_wonder", "gold_ship",
	"mejiro_mcqueen", "oguri_cap", "agnes_digital",
	"tokai_teio", "silence_suzuka", "tm_opera_o",
]


static func home_team() -> Array[PlayerData]:
	return _build_team("home", HOME_ORDER)


static func away_team() -> Array[PlayerData]:
	return _build_team("away", AWAY_ORDER)


static func _build_team(prefix: String, order: Array) -> Array[PlayerData]:
	var slots: Array = FormationManager.get_slots(FormationManager.DEFAULT_FORMATION)
	var roster: Array[PlayerData] = []
	for i in range(slots.size()):
		var role: String = slots[i]["role"]
		var visual_id: String = order[i]
		var stats: Array = CHARACTER_BASE_STATS[visual_id]

		var data := PlayerData.new()
		data.id = "%s_%d_%s" % [prefix, i, visual_id]
		data.display_name = DISPLAY_NAMES.get(visual_id, visual_id)
		data.position = FormationManager.role_category(role)
		data.movement_speed = stats[0]
		data.acceleration = stats[1]
		data.sprint_speed = stats[2]
		data.passing = stats[3]
		data.shooting = stats[4]
		data.dribbling = stats[5]
		data.stamina = stats[6]
		data.defensive_ability = stats[7]
		data.preferred_foot = stats[8]
		data.visual_id = visual_id
		roster.append(data)
	return roster
