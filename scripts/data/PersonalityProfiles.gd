class_name PersonalityProfiles
extends RefCounted

## Data-driven personality profiles, keyed by the same character identity
## string as CharacterRegistry's visual_id (both are facets of "which Uma
## Musume is this" -- visuals and personality are still fully independent
## systems that happen to share a lookup key for convenience; stats
## (PlayerData) remain a completely separate axis).
##
## These are fan-game interpretations of each character's public
## personality for THIS project, not claims about official game mechanics.
## Mejiro McQueen has no personality description in the design brief this
## was built from -- her profile below is this project's own
## interpretation (composed, disciplined, quietly confident), consistent
## with how every other profile here is also an interpretation.
##
## Adding a new character's personality later is one more entry here --
## nothing about PersonalityEventSystem, AIController, or FootballPlayer
## needs to change.

const PROFILES := {
	# Chaotic, unpredictable, low motivation when nothing is happening --
	# but genuinely competitive in bursts. See PersonalityEvents.gd for
	# her "bored_sit" / "wander_off" / "sudden_sprint" spontaneous events.
	"gold_ship": {
		"confidence": 70.0, "discipline": 15.0, "aggression": 55.0, "competitiveness": 65.0,
		"playfulness": 95.0, "impulsiveness": 90.0, "composure": 35.0, "teamwork": 30.0,
		"stamina_management": 40.0, "tactical_awareness": 20.0, "showmanship": 60.0,
		"laziness": 75.0, "risk_taking": 85.0,
	},
	# Extreme confidence and showmanship -- theatrical, dramatic, willing
	# to attempt flashy plays.
	"tm_opera_o": {
		"confidence": 95.0, "discipline": 55.0, "aggression": 60.0, "competitiveness": 75.0,
		"playfulness": 55.0, "impulsiveness": 55.0, "composure": 65.0, "teamwork": 50.0,
		"stamina_management": 55.0, "tactical_awareness": 55.0, "showmanship": 95.0,
		"laziness": 20.0, "risk_taking": 70.0,
	},
	# Straightforward, strongly competitive, reliable, direct.
	"oguri_cap": {
		"confidence": 75.0, "discipline": 65.0, "aggression": 60.0, "competitiveness": 90.0,
		"playfulness": 35.0, "impulsiveness": 45.0, "composure": 65.0, "teamwork": 60.0,
		"stamina_management": 60.0, "tactical_awareness": 55.0, "showmanship": 30.0,
		"laziness": 15.0, "risk_taking": 55.0,
	},
	# Energetic, competitive, aggressive challenges, expressive attacker.
	"tamamo_cross": {
		"confidence": 70.0, "discipline": 45.0, "aggression": 80.0, "competitiveness": 80.0,
		"playfulness": 65.0, "impulsiveness": 65.0, "composure": 45.0, "teamwork": 55.0,
		"stamina_management": 45.0, "tactical_awareness": 40.0, "showmanship": 55.0,
		"laziness": 15.0, "risk_taking": 70.0,
	},
	# Seeks open space, forward runs, separation from defenders rather
	# than constantly chasing the ball.
	"silence_suzuka": {
		"confidence": 65.0, "discipline": 55.0, "aggression": 45.0, "competitiveness": 65.0,
		"playfulness": 35.0, "impulsiveness": 40.0, "composure": 60.0, "teamwork": 50.0,
		"stamina_management": 50.0, "tactical_awareness": 70.0, "showmanship": 30.0,
		"laziness": 15.0, "risk_taking": 65.0,
	},
	# Disciplined, tactically aware, leadership, controlled decisions.
	"symboli_rudolf": {
		"confidence": 75.0, "discipline": 90.0, "aggression": 40.0, "competitiveness": 70.0,
		"playfulness": 15.0, "impulsiveness": 15.0, "composure": 80.0, "teamwork": 85.0,
		"stamina_management": 70.0, "tactical_awareness": 90.0, "showmanship": 25.0,
		"laziness": 10.0, "risk_taking": 25.0,
	},
	# Discipline, positional awareness, organized, low tolerance for chaos.
	"air_groove": {
		"confidence": 70.0, "discipline": 85.0, "aggression": 45.0, "competitiveness": 65.0,
		"playfulness": 20.0, "impulsiveness": 20.0, "composure": 75.0, "teamwork": 80.0,
		"stamina_management": 65.0, "tactical_awareness": 80.0, "showmanship": 25.0,
		"laziness": 10.0, "risk_taking": 30.0,
	},
	# Composure, controlled decisions, patience, efficient movement.
	"grass_wonder": {
		"confidence": 65.0, "discipline": 75.0, "aggression": 30.0, "competitiveness": 55.0,
		"playfulness": 25.0, "impulsiveness": 15.0, "composure": 90.0, "teamwork": 65.0,
		"stamina_management": 80.0, "tactical_awareness": 70.0, "showmanship": 20.0,
		"laziness": 25.0, "risk_taking": 25.0,
	},
	# Energetic attacking, confidence, enthusiasm, expressive reactions.
	"tokai_teio": {
		"confidence": 85.0, "discipline": 55.0, "aggression": 65.0, "competitiveness": 75.0,
		"playfulness": 55.0, "impulsiveness": 55.0, "composure": 55.0, "teamwork": 55.0,
		"stamina_management": 50.0, "tactical_awareness": 50.0, "showmanship": 50.0,
		"laziness": 10.0, "risk_taking": 65.0,
	},
	# Energetic, highly enthusiastic; gets unusually excited around notable
	# teammates or big plays (see "excited_reaction" event).
	"agnes_digital": {
		"confidence": 65.0, "discipline": 50.0, "aggression": 40.0, "competitiveness": 55.0,
		"playfulness": 85.0, "impulsiveness": 60.0, "composure": 45.0, "teamwork": 60.0,
		"stamina_management": 45.0, "tactical_awareness": 45.0, "showmanship": 70.0,
		"laziness": 20.0, "risk_taking": 50.0,
	},
	# This project's own interpretation (no behavior brief was given for
	# her): composed, disciplined, quietly confident.
	"mejiro_mcqueen": {
		"confidence": 75.0, "discipline": 80.0, "aggression": 35.0, "competitiveness": 65.0,
		"playfulness": 25.0, "impulsiveness": 25.0, "composure": 85.0, "teamwork": 60.0,
		"stamina_management": 65.0, "tactical_awareness": 65.0, "showmanship": 45.0,
		"laziness": 15.0, "risk_taking": 35.0,
	},
}


static func get_profile(key: String) -> PersonalityData:
	var data := PersonalityData.new()
	var values: Dictionary = PROFILES.get(key, {})
	for trait_name in values:
		data.set(trait_name, values[trait_name])
	return data
