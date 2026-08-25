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
}


static func get_scene(visual_id: String) -> PackedScene:
	if visual_id == "" or not MODELS.has(visual_id):
		return null
	var path: String = MODELS[visual_id]
	if not ResourceLoader.exists(path):
		push_warning("CharacterRegistry: model file missing for '%s' at %s" % [visual_id, path])
		return null
	return load(path)
