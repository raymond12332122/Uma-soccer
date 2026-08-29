extends Node

## v0.9.2: what slots does Godot's humanoid profile actually define? The
## retarget layer maps both the Mixamo pack and every Uma rig onto these
## names, so the mapping tables have to be built against the real list.

func _ready() -> void:
	var p := SkeletonProfileHumanoid.new()
	print("PROFILE: %d bones" % p.bone_size)
	var names: Array = []
	for i in range(p.bone_size):
		names.append(p.get_bone_name(i))
	print("PROFILE: %s" % ", ".join(names))
	get_tree().quit()
