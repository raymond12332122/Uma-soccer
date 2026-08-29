extends SceneTree

## v0.9.2 retarget layer (brief section 2).
##
## The animation pack and the character models share NO bone names:
##
##   pack   65 bones,  root 'mixamorig_Hips',  Mixamo naming
##   models 399-440 bones, root '_rootJoint',  Japanese game rig naming
##          (Hip_04, Waist_0102, Sp_Hi_MSkirt0_B_00_05, ...)
##
## and every character has a DIFFERENT bone count, so the numeric suffix on
## each bone shifts from model to model (Hip_04 on Gold Ship, Hip_05 on Tokai
## Teio). Hand-authoring twelve BoneMaps would be unmaintainable and would
## break the moment a model is re-exported.
##
## Both rigs are systematic, though, so the maps are GENERATED: each humanoid
## slot has a regex, the regex is matched against the real skeleton, and the
## result is written as a BoneMap resource. Re-running this after an asset
## change reproduces the maps exactly.
##
## Only the ~23 slots football needs are mapped. Fingers, eyes and jaw are
## deliberately left empty -- no clip in the pack animates them meaningfully,
## and mapping them would only add ways to be wrong.
##
## Run:  godot --headless --path . --script tools/generate_bone_maps.gd

const CHAR_DIR := "res://assets/characters"
const ANIM_DIR := "res://assets/animations/source"
const OUT_DIR := "res://assets/animations/bone_maps"

## profile slot -> regex matching the bone on a UMA rig.
##
## Anchored and digit-suffixed on purpose. A bare prefix match would grab the
## decoys these rigs are full of: 'Head_attach_0178' for Head,
## 'Ankle_offset_L_070' for the foot, 'Toe_offset_L_072' for the toes.
const UMA_PATTERNS := {
	"Hips": "^Hip_\\d+$",
	"Spine": "^Waist_\\d+$",
	"Chest": "^Spine_\\d+$",
	"UpperChest": "^Chest_\\d+$",
	"Neck": "^Neck_\\d+$",
	"Head": "^Head_\\d+$",
	"LeftShoulder": "^Shoulder_L_\\d+$",
	"LeftUpperArm": "^Arm_L_\\d+$",
	"LeftLowerArm": "^Elbow_L_\\d+$",
	"LeftHand": "^Wrist_L_\\d+$",
	"RightShoulder": "^Shoulder_R_\\d+$",
	"RightUpperArm": "^Arm_R_\\d+$",
	"RightLowerArm": "^Elbow_R_\\d+$",
	"RightHand": "^Wrist_R_\\d+$",
	"LeftUpperLeg": "^Thigh_L_\\d+$",
	"LeftLowerLeg": "^Knee_L_\\d+$",
	"LeftFoot": "^Ankle_L_\\d+$",
	"LeftToes": "^Toe_L_\\d+$",
	"RightUpperLeg": "^Thigh_R_\\d+$",
	"RightLowerLeg": "^Knee_R_\\d+$",
	"RightFoot": "^Ankle_R_\\d+$",
	"RightToes": "^Toe_R_\\d+$",
}

## profile slot -> exact bone name on the Mixamo pack skeleton.
const MIXAMO_MAP := {
	"Hips": "mixamorig_Hips",
	"Spine": "mixamorig_Spine",
	"Chest": "mixamorig_Spine1",
	"UpperChest": "mixamorig_Spine2",
	"Neck": "mixamorig_Neck",
	"Head": "mixamorig_Head",
	"LeftShoulder": "mixamorig_LeftShoulder",
	"LeftUpperArm": "mixamorig_LeftArm",
	"LeftLowerArm": "mixamorig_LeftForeArm",
	"LeftHand": "mixamorig_LeftHand",
	"RightShoulder": "mixamorig_RightShoulder",
	"RightUpperArm": "mixamorig_RightArm",
	"RightLowerArm": "mixamorig_RightForeArm",
	"RightHand": "mixamorig_RightHand",
	"LeftUpperLeg": "mixamorig_LeftUpLeg",
	"LeftLowerLeg": "mixamorig_LeftLeg",
	"LeftFoot": "mixamorig_LeftFoot",
	"LeftToes": "mixamorig_LeftToeBase",
	"RightUpperLeg": "mixamorig_RightUpLeg",
	"RightLowerLeg": "mixamorig_RightLeg",
	"RightFoot": "mixamorig_RightFoot",
	"RightToes": "mixamorig_RightToeBase",
}


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	# --- the pack: one skeleton shared by all 54 clips, so one map ---
	var pack_skel: Skeleton3D = _skeleton_of(ANIM_DIR + "/jog forward.fbx")
	if pack_skel == null:
		printerr("BONEMAP: could not read the pack skeleton")
		return
	var pack_map := _build_exact(pack_skel, MIXAMO_MAP)
	_save(pack_map, OUT_DIR + "/mixamo_pack.tres", "animation pack", pack_skel)

	# --- every character, matched by pattern ---
	var d := DirAccess.open(CHAR_DIR)
	d.list_dir_begin()
	var n: String = d.get_next()
	var chars: Array = []
	while n != "":
		if d.current_is_dir() and not n.begins_with("."):
			chars.append(n)
		n = d.get_next()
	d.list_dir_end()
	chars.sort()

	for c in chars:
		var path := "%s/%s/%s.glb" % [CHAR_DIR, c, c]
		if not ResourceLoader.exists(path):
			continue
		var skel: Skeleton3D = _skeleton_of(path)
		if skel == null:
			printerr("BONEMAP: %s has no skeleton" % c)
			continue
		# Once retargeting is switched on the import RENAMES these bones to the
		# profile's slot names, so re-running against a retargeted import would
		# match nothing and silently overwrite a good map with an empty one.
		# Detect that and keep what is there; regenerating means turning
		# retargeting off first (tools/apply_retarget_imports.gd writes it).
		if skel.find_bone("Hips") >= 0:
			print("BONEMAP: %-20s already retargeted -- keeping existing map" % c)
			continue
		var bm := _build_regex(skel, UMA_PATTERNS)
		_save(bm, "%s/%s.tres" % [OUT_DIR, c], c, skel)

	print("BONEMAP: done")
	quit()


## Build a BoneMap from exact bone names.
func _build_exact(skel: Skeleton3D, table: Dictionary) -> BoneMap:
	var bm := BoneMap.new()
	bm.profile = SkeletonProfileHumanoid.new()
	for slot in table.keys():
		if skel.find_bone(table[slot]) >= 0:
			bm.set_skeleton_bone_name(slot, table[slot])
	return bm


## Build a BoneMap by matching each slot's regex against the real skeleton.
func _build_regex(skel: Skeleton3D, patterns: Dictionary) -> BoneMap:
	var bm := BoneMap.new()
	bm.profile = SkeletonProfileHumanoid.new()
	for slot in patterns.keys():
		var re := RegEx.new()
		re.compile(patterns[slot])
		var found := ""
		var matches := 0
		for i in range(skel.get_bone_count()):
			var bone: String = skel.get_bone_name(i)
			if re.search(bone) != null:
				matches += 1
				if found == "":
					found = bone
		if matches > 1:
			printerr("BONEMAP: slot %s matched %d bones (%s ...) -- pattern is ambiguous"
				% [slot, matches, found])
		if found != "":
			bm.set_skeleton_bone_name(slot, found)
	return bm


func _save(bm: BoneMap, path: String, label: String, skel: Skeleton3D) -> void:
	var mapped := 0
	var missing: Array = []
	for slot in UMA_PATTERNS.keys():
		if bm.get_skeleton_bone_name(slot) != "":
			mapped += 1
		else:
			missing.append(slot)
	var err := ResourceSaver.save(bm, path)
	print("BONEMAP: %-20s %d/%d slots mapped from %d bones -> %s%s" % [
		label, mapped, UMA_PATTERNS.size(), skel.get_bone_count(), path,
		"" if missing.is_empty() else "  MISSING: " + ", ".join(missing)])
	if err != OK:
		printerr("BONEMAP: save failed for %s (%d)" % [path, err])


func _skeleton_of(scene_path: String) -> Skeleton3D:
	var packed: PackedScene = load(scene_path)
	if packed == null:
		return null
	var root: Node = packed.instantiate()
	var s: Skeleton3D = _find(root)
	return s


func _find(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var r: Skeleton3D = _find(c)
		if r != null:
			return r
	return null
