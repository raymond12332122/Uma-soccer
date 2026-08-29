extends SceneTree

## v0.9.2: did retargeting actually work? (brief section 2)
##
## The claim to verify is narrow and checkable: after import-time renaming, a
## character skeleton and the animation pack must use the SAME bone names for
## the humanoid core, and every clip track must address a bone that exists on
## the character. Anything less and the clip silently animates nothing --
## which is exactly what the first attempt did, with the retarget options
## written to a place the importer never reads.
##
## Runs across the WHOLE roster and the WHOLE pack, because "it worked on
## gold_ship" is not the claim being made. The per-character track-landing
## count is the honest source for the report's COMPATIBLE number.

const CHAR_DIR := "res://assets/characters"
const ANIM_DIR := "res://assets/animations/source"

## The bones football actually needs to look right. Fingers/eyes/jaw are
## deliberately not mapped, so they are deliberately not checked.
const CORE := ["Hips", "Spine", "Chest", "Neck", "Head",
	"LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "LeftToes",
	"RightUpperLeg", "RightLowerLeg", "RightFoot", "RightToes",
	"LeftUpperArm", "LeftLowerArm", "LeftHand",
	"RightUpperArm", "RightLowerArm", "RightHand"]


func _initialize() -> void:
	# ---- 1. every clip: which bones does it drive, and does it still exist ----
	var clip_files: Array = _files(ANIM_DIR, ".fbx")
	var all_track_bones := {}
	var clips_ok := 0
	var clips_empty: Array = []
	print("RETARGET: ---- animation pack (%d files) ----" % clip_files.size())
	for f in clip_files:
		var anim: Animation = _first_anim(f)
		if anim == null:
			clips_empty.append(f.get_file() + " (no clip)")
			continue
		var bones := {}
		for t in range(anim.get_track_count()):
			var p: String = str(anim.track_get_path(t))
			if ":" in p:
				bones[p.split(":")[-1]] = true
		for b in bones:
			all_track_bones[b] = true
		if bones.is_empty():
			clips_empty.append(f.get_file() + " (no bone tracks)")
		else:
			clips_ok += 1
	print("RETARGET: %d/%d clips drive bones; %d distinct bones addressed across the pack" % [
		clips_ok, clip_files.size(), all_track_bones.size()])
	if not clips_empty.is_empty():
		print("RETARGET: clips driving nothing: %s" % ", ".join(clips_empty))

	# Anything the pack drives that is NOT a profile slot cannot land on an
	# Uma rig -- unmapped-track removal is supposed to have taken those out.
	var non_profile: Array = []
	for b in all_track_bones.keys():
		if not (b in CORE) and not (b in ["LeftShoulder", "RightShoulder", "UpperChest"]):
			non_profile.append(b)
	non_profile.sort()
	print("RETARGET: pack bones outside the mapped humanoid core: %s" % [
		"none" if non_profile.is_empty() else ", ".join(non_profile)])

	# ---- 2. every character: are those bones there? ----
	print("RETARGET: ---- roster ----")
	var full := 0
	var chars: Array = _dirs(CHAR_DIR)
	for c in chars:
		var cs: Skeleton3D = _skel("%s/%s/%s.glb" % [CHAR_DIR, c, c])
		if cs == null:
			print("RETARGET: %-16s FAILED to load" % c)
			continue
		var names := {}
		for i in range(cs.get_bone_count()):
			names[cs.get_bone_name(i)] = true
		var missing_core: Array = []
		for slot in CORE:
			if not names.has(slot):
				missing_core.append(slot)
		var hit := 0
		var missed: Array = []
		for b in all_track_bones.keys():
			if names.has(b):
				hit += 1
			else:
				missed.append(b)
		missed.sort()
		var ok: bool = missing_core.is_empty() and missed.is_empty()
		if ok:
			full += 1
		print("RETARGET: %-16s %4d bones | core %2d/%d | pack tracks %d/%d land%s" % [
			c, cs.get_bone_count(), CORE.size() - missing_core.size(), CORE.size(),
			hit, all_track_bones.size(),
			"" if ok else "  MISSING: " + ", ".join(missing_core + missed)])

	print("RETARGET: ---- %d/%d characters take every track the pack drives ----" % [
		full, chars.size()])
	quit()


func _skel(path: String) -> Skeleton3D:
	var p: PackedScene = load(path)
	return _find(p.instantiate()) if p != null else null


func _first_anim(path: String) -> Animation:
	var p: PackedScene = load(path)
	if p == null:
		return null
	var ap: AnimationPlayer = _find_ap(p.instantiate())
	if ap == null:
		return null
	for n in ap.get_animation_list():
		return ap.get_animation(n)
	return null


func _find(n: Node) -> Skeleton3D:
	if n is Skeleton3D: return n
	for c in n.get_children():
		var r: Skeleton3D = _find(c)
		if r != null: return r
	return null


func _find_ap(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer: return n
	for c in n.get_children():
		var r: AnimationPlayer = _find_ap(c)
		if r != null: return r
	return null


func _dirs(path: String) -> Array:
	var out: Array = []
	var d := DirAccess.open(path)
	if d == null: return out
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
	if d == null: return out
	d.list_dir_begin()
	var n: String = d.get_next()
	while n != "":
		if not d.current_is_dir() and n.to_lower().ends_with(suffix):
			out.append(path + "/" + n)
		n = d.get_next()
	d.list_dir_end()
	out.sort()
	return out
