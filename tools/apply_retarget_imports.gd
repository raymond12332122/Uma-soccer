extends SceneTree

## v0.9.2 retarget layer, step 2 (brief section 2): switch retargeting ON.
##
## Step 1 (tools/generate_bone_maps.gd) worked out WHICH bone on each rig
## fills each humanoid slot. This step tells the importer to use those maps,
## which renames each rig's humanoid core onto the profile's slot names --
## 'Hip_04' and 'mixamorig_Hips' both become 'Hips' -- so a clip authored on
## one rig plays on the other with no per-frame cost at all. That last part is
## why this is done at import rather than at runtime: 22 animated players.
##
## WHERE THESE OPTIONS LIVE, because getting this wrong fails silently:
## retarget/* are NOT top-level scene-import options. They are INTERNAL
## options belonging to a specific Skeleton3D node, and the importer reads
## them out of the .import file's `_subresources` dictionary under
##
##     _subresources = { "nodes": { "PATH:<path to the skeleton>": { ... } } }
##
## where the key is the node's import id, which defaults to "PATH:" plus the
## node's path from the scene root. Written at top level instead, Godot drops
## the keys on the next reimport and reports nothing: the first attempt at
## this produced .import files with no retarget block and characters with
## 0/19 slots renamed. The skeleton path differs per character
## ('Sketchfab_model/<hash>_fbx/RootNode/Object_3/Skeleton3D'), so it is read
## off the real imported scene rather than assumed.
##
## Only the ~22 mapped humanoid bones are renamed. The several hundred skirt,
## hair and accessory bones on each Uma rig keep their names.
##
## Run:  godot --headless --path . --script tools/apply_retarget_imports.gd
## Then: godot --headless --path . --import
## Then: godot --headless --path . --script tests/diag_retarget_verify.gd

const CHAR_DIR := "res://assets/characters"
const ANIM_DIR := "res://assets/animations/source"
const MAPS := "res://assets/animations/bone_maps"

## Retarget settings applied to BOTH sides. They have to agree: retargeting
## only works if source and destination land in the same reference pose.
##
## fix_silhouette is ON because the rigs do NOT share a rest pose -- Mixamo
## ships a T-pose, these models do not. Without it the clips would play on a
## skeleton whose arms start somewhere else, and every rotation would carry
## that difference as a permanent offset.
##
## make_unique is OFF deliberately: it would rename the Skeleton3D node to
## 'GeneralSkeleton', changing node paths that the animation track paths and
## AnimationController's lookups depend on. Nothing here needs it -- the
## skeleton is found by type, not by name.
const RETARGET := {
	"retarget/bone_renamer/rename_bones": true,
	"retarget/bone_renamer/unique_node/make_unique": false,
	"retarget/rest_fixer/apply_node_transforms": true,
	"retarget/rest_fixer/normalize_position_tracks": true,
	"retarget/rest_fixer/overwrite_axis": true,
	"retarget/rest_fixer/keep_global_rest_on_leftovers": true,
	"retarget/rest_fixer/reset_all_bone_poses_after_import": true,
	"retarget/rest_fixer/fix_silhouette/enable": true,
	"retarget/rest_fixer/fix_silhouette/threshold": 15.0,
	"retarget/rest_fixer/fix_silhouette/base_height_adjustment": 0.0,
	"retarget/rest_fixer/fix_silhouette/filter": [],
}

## Extra settings for the clip files only. Dropping tracks for bones that no
## humanoid slot claims is not tidying: the pack's 52 animated bones include
## 30 finger/twist bones that exist on no Uma rig, and a track addressing a
## missing bone is dead weight carried by every one of 22 players.
const RETARGET_ANIM_EXTRA := {
	"retarget/remove_tracks/unmapped_bones": true,
	"retarget/remove_tracks/unimportant_positions": true,
	"retarget/remove_tracks/except_bone_transform": false,
}

## A character is a MODEL: keep its meshes, drop any clips it ships (none of
## them are football, and they would collide with the pack by name).
const CHAR_PARAMS := {"animation/import": false}

## A clip file is an ANIMATION: its mesh is a Mixamo mannequin nobody renders,
## so importing 54 of them would ship 54 unused meshes.
##
## trimming is turned OFF against the FBX importer's default, but NOT because
## it fixed anything -- that hypothesis was tested and falsified, and the
## setting is kept only because importing what the file actually contains is
## the more honest default.
##
## The hypothesis was: 'kick soccerball' measures 0.57s long with the boot
## reaching the ball at 0.51s, leaving 0.06s of visible kick, and trimming
## (which strips the still head and tail of a clip) had eaten the
## follow-through. Since gameplay launches the ball on the decision frame,
## the follow-through is the only part of a strike clip that is ever played,
## so this would have mattered a great deal. Reimporting all 54 with
## trimming=false produced byte-identical durations: the clips genuinely end
## at contact. AnimationSet's choice of strike clips is made on that measured
## basis instead -- see its UNUSED table.
const ANIM_PARAMS := {
	"animation/import": true,
	"animation/trimming": false,
	"meshes/generate_lods": false,
	"meshes/create_shadow_meshes": false,
}


func _initialize() -> void:
	var n_char := 0
	for c in _dirs(CHAR_DIR):
		var scene_path := "%s/%s/%s.glb" % [CHAR_DIR, c, c]
		var map_path := "%s/%s.tres" % [MAPS, c]
		if not ResourceLoader.exists(scene_path):
			continue
		if not ResourceLoader.exists(map_path):
			printerr("RETARGET-SET: no bone map for %s" % c)
			continue
		if _apply(scene_path, map_path, CHAR_PARAMS, {}):
			n_char += 1

	var n_anim := 0
	for f in _files(ANIM_DIR, ".fbx"):
		if _apply(f, MAPS + "/mixamo_pack.tres", ANIM_PARAMS, RETARGET_ANIM_EXTRA):
			n_anim += 1

	print("RETARGET-SET: %d character imports, %d animation imports" % [n_char, n_anim])
	quit()


## Rewrite one .import file so its skeleton retargets through `map_path`.
func _apply(scene_path: String, map_path: String, params: Dictionary, extra: Dictionary) -> bool:
	var skel_path: String = _skeleton_path(scene_path)
	if skel_path == "":
		printerr("RETARGET-SET: no Skeleton3D in %s" % scene_path)
		return false
	var bone_map: BoneMap = load(map_path)
	if bone_map == null:
		printerr("RETARGET-SET: cannot load %s" % map_path)
		return false

	var import_path := scene_path + ".import"
	var cfg := ConfigFile.new()
	var err := cfg.load(import_path)
	if err != OK:
		printerr("RETARGET-SET: cannot read %s (%d)" % [import_path, err])
		return false

	var opts := {}
	for k in RETARGET:
		opts[k] = RETARGET[k]
	for k in extra:
		opts[k] = extra[k]
	opts["retarget/bone_map"] = bone_map

	# Preserve any node entries already there (materials/animations too) and
	# replace only this skeleton's block, so re-running is idempotent.
	var subres: Dictionary = cfg.get_value("params", "_subresources", {})
	var nodes: Dictionary = subres.get("nodes", {})
	nodes["PATH:" + skel_path] = opts
	subres["nodes"] = nodes
	cfg.set_value("params", "_subresources", subres)

	for k in params:
		cfg.set_value("params", k, params[k])

	err = cfg.save(import_path)
	if err != OK:
		printerr("RETARGET-SET: cannot write %s (%d)" % [import_path, err])
		return false
	print("RETARGET-SET: %-46s skeleton '%s'" % [scene_path.get_file(), skel_path])
	return true


## The skeleton's path from the scene root, which is what the importer keys
## its internal options by. Read from the actual import rather than guessed:
## it is a different five-level path on every character.
func _skeleton_path(scene_path: String) -> String:
	var packed: PackedScene = load(scene_path)
	if packed == null:
		return ""
	var root: Node = packed.instantiate()
	var skel: Skeleton3D = _find(root)
	if skel == null:
		return ""
	return str(root.get_path_to(skel))


func _find(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var r: Skeleton3D = _find(c)
		if r != null:
			return r
	return null


func _dirs(path: String) -> Array:
	var out: Array = []
	var d := DirAccess.open(path)
	if d == null:
		return out
	d.list_dir_begin()
	var n: String = d.get_next()
	while n != "":
		if d.current_is_dir() and not n.begins_with("."):
			out.append(n)
		n = d.get_next()
	d.list_dir_end()
	out.sort()
	return out


func _files(path: String, suffix: String) -> Array:
	var out: Array = []
	var d := DirAccess.open(path)
	if d == null:
		return out
	d.list_dir_begin()
	var n: String = d.get_next()
	while n != "":
		if not d.current_is_dir() and n.to_lower().ends_with(suffix):
			out.append(path + "/" + n)
		n = d.get_next()
	d.list_dir_end()
	out.sort()
	return out
