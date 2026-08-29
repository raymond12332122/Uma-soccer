extends Node

## v0.9.2: is there a consistently named HUMANOID CORE under the physics
## bones? Godot's retargeting (BoneMap + SkeletonProfileHumanoid) needs one
## bone per humanoid slot. 400+ bone rigs are mostly skirt/hair chains; what
## matters is whether hips/spine/chest/neck/head/arms/legs are findable and
## named the same way on every character.

const DIR := "res://assets/characters"
const CORE := ["hip", "spine", "chest", "neck", "head", "shoulder", "arm",
	"elbow", "hand", "wrist", "leg", "knee", "ankle", "foot", "toe", "waist",
	"thigh", "calf", "clavicle"]


func _ready() -> void:
	for c in ["gold_ship", "tokai_teio", "agnes_digital"]:
		_dump(c)
	get_tree().quit()


func _dump(char_name: String) -> void:
	var path := "%s/%s/%s.glb" % [DIR, char_name, char_name]
	var packed: PackedScene = load(path)
	if packed == null:
		return
	var root: Node = packed.instantiate()
	var skel: Skeleton3D = _find_skeleton(root)
	if skel == null:
		root.queue_free()
		return
	var hits: Array = []
	for i in range(skel.get_bone_count()):
		var n: String = skel.get_bone_name(i)
		var low: String = n.to_lower()
		# Skip the obvious physics chains so the core is visible.
		if low.begins_with("sp_") or low.contains("skirt") or low.contains("hair") \
			or low.contains("handle") or low.contains("ribbon") or low.contains("tail"):
			continue
		for k in CORE:
			if low.contains(k):
				hits.append("%s(parent=%s)" % [n, skel.get_bone_name(skel.get_bone_parent(i)) if skel.get_bone_parent(i) >= 0 else "-"])
				break
	print("BONE-CORE: %s -- %d total bones, %d core-looking:" % [
		char_name, skel.get_bone_count(), hits.size()])
	for h in hits:
		print("BONE-CORE:    %s" % h)
	root.queue_free()


func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var r: Skeleton3D = _find_skeleton(c)
		if r != null:
			return r
	return null
