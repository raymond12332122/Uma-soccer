class_name CharacterRegistry
extends RefCounted

## Data-driven map from a PlayerData.visual_id string to the character
## model scene that should be displayed. This is the entire "process for
## adding another character model": drop the .glb/.gltf under
## assets/characters/<name>/, add one line here, then set
## PlayerData.visual_id to that key on whichever roster entry should use
## it. No FootballPlayer/AnimationController code needs to change.

const MODELS := {
	"tokai_teio": "res://assets/characters/tokai_teio/tokai_teio.glb",
	"agnes_digital": "res://assets/characters/agnes_digital/agnes_digital.glb",
	"tamamo_cross": "res://assets/characters/tamamo_cross/tamamo_cross.glb",
	"oguri_cap": "res://assets/characters/oguri_cap/oguri_cap.glb",
	"gold_ship": "res://assets/characters/gold_ship/gold_ship.glb",
	"symboli_rudolf": "res://assets/characters/symboli_rudolf/symboli_rudolf.glb",
	"air_groove": "res://assets/characters/air_groove/air_groove.glb",
	"tm_opera_o": "res://assets/characters/tm_opera_o/tm_opera_o.glb",
	"grass_wonder": "res://assets/characters/grass_wonder/grass_wonder.glb",
	"mejiro_mcqueen": "res://assets/characters/mejiro_mcqueen/mejiro_mcqueen.glb",
	"silence_suzuka": "res://assets/characters/silence_suzuka/silence_suzuka.glb",
}


static func get_scene(visual_id: String) -> PackedScene:
	if visual_id == "" or not MODELS.has(visual_id):
		return null
	var path: String = MODELS[visual_id]
	if not ResourceLoader.exists(path):
		push_warning("CharacterRegistry: model file missing for '%s' at %s" % [visual_id, path])
		return null
	return load(path)
