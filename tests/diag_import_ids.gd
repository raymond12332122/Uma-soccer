extends SceneTree

## v0.9.2: what node paths / import ids does the scene importer see?
##
## Godot's retarget options are per-Skeleton3D INTERNAL import options, keyed in
## the .import file's `_subresources` dictionary. The key is the node's
## "import_id" meta, which the importer defaults to "PATH:<path from root>".
## Guessing that key would silently do nothing, so read it off a real import.

const TARGETS := [
	"res://assets/characters/gold_ship/gold_ship.glb",
	"res://assets/animations/source/jog forward.fbx",
]


func _initialize() -> void:
	for path in TARGETS:
		var p: PackedScene = load(path)
		if p == null:
			print("IDS: %s FAILED" % path)
			continue
		var root: Node = p.instantiate()
		print("IDS: ---- %s (root '%s' %s) ----" % [path, root.name, root.get_class()])
		_walk(root, root, 0)
	quit()


func _walk(root: Node, n: Node, depth: int) -> void:
	var meta: String = str(n.get_meta("import_id")) if n.has_meta("import_id") else "-"
	print("IDS:   %s%s [%s]  path='%s'  import_id=%s" % [
		"  ".repeat(depth), n.name, n.get_class(), root.get_path_to(n), meta])
	if depth >= 8:
		return
	for c in n.get_children():
		_walk(root, c, depth + 1)
