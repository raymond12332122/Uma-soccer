extends Node

## v0.9.2 (brief section 2): do the Uma models share a skeleton with the
## animation pack? The pack is uniform (65 bones, mixamorig_Hips). If the
## characters are not, every clip needs retargeting and that is the milestone's
## real cost.

const DIR := "res://assets/characters"


func _ready() -> void:
	var d := DirAccess.open(DIR)
	d.list_dir_begin()
	var name: String = d.get_next()
	var sigs := {}
	while name != "":
		if d.current_is_dir() and not name.begins_with("."):
			var path := "%s/%s/%s.glb" % [DIR, name, name]
			if ResourceLoader.exists(path):
				_report(name, path, sigs)
		name = d.get_next()
	d.list_dir_end()
	print("MODEL-SKEL: ---- distinct skeleton signatures ----")
	for k in sigs.keys():
		print("MODEL-SKEL:   %s -> %s" % [k, sigs[k]])
	get_tree().quit()


func _report(char_name: String, path: String, sigs: Dictionary) -> void:
	var packed: PackedScene = load(path)
	if packed == null:
		print("MODEL-SKEL: %s | FAILED TO LOAD" % char_name)
		return
	var root: Node = packed.instantiate()
	var skel: Skeleton3D = _find_skeleton(root)
	if skel == null:
		print("MODEL-SKEL: %s | NO SKELETON" % char_name)
		root.queue_free()
		return
	var n: int = skel.get_bone_count()
	var first: String = skel.get_bone_name(0)
	# A few landmark bones, to see whether the naming scheme matches Mixamo.
	var names: Array = []
	for i in range(mini(n, 6)):
		names.append(skel.get_bone_name(i))
	var has_mixamo := false
	for i in range(n):
		if skel.get_bone_name(i).begins_with("mixamorig"):
			has_mixamo = true
			break
	var sig := "%d bones, root '%s', mixamo naming: %s" % [n, first, has_mixamo]
	sigs[sig] = str(sigs.get(sig, "")) + char_name + " "
	print("MODEL-SKEL: %-20s | %d bones | root '%s' | mixamo:%s | first: %s" % [
		char_name, n, first, has_mixamo, ", ".join(names)])
	root.queue_free()


func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var r: Skeleton3D = _find_skeleton(c)
		if r != null:
			return r
	return null
