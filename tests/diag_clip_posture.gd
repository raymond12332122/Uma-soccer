extends SceneTree

## v0.9.2.2: classify every mapped clip by its REAL MOTION (brief section 3).
##
## The brief is explicit that clips may have been categorised from filenames
## and heuristics rather than from what they actually do, and that ambiguous
## ones should be deferred rather than assigned blindly.
##
## The measurement is posture: how high the hips sit through the clip, as a
## fraction of the same rig's standing rest height. A player on the floor has
## their hips at ankle height, and that is true whatever the file is called.
##
##   UPRIGHT   hips stay above 0.70 of rest
##   CROUCH    dips to 0.40-0.70
##   GROUNDED  drops below 0.40 -- on or near the floor
##
## This is what tells a "standing tackle" from a "slide tackle" without
## trusting either filename, and it is how the grounded poses QA is seeing
## were traced to specific clips.

const CLIP_DIR := "res://assets/animations/source"
const SAMPLE_HZ := 30.0

const GROUNDED_FRAC := 0.40
const CROUCH_FRAC := 0.70


func _initialize() -> void:
	print("POSTURE: clip | category | min_hips | mean_hips | posture")
	var rows: Array = []
	for intent in AnimationSet.INTENTS:
		var entry: Dictionary = AnimationSet.INTENTS[intent]
		var cat: String = AnimationSet.Category.keys()[entry["category"]]
		for opt in entry["clips"]:
			var m: Dictionary = _measure(opt["clip"], opt["start"], opt["tail"])
			if m.is_empty():
				continue
			rows.append({
				"intent": intent, "clip": opt["clip"], "cat": cat,
				"min": m["min"], "mean": m["mean"], "posture": m["posture"],
			})
	rows.sort_custom(func(a, b): return a["min"] < b["min"])
	for r in rows:
		print("POSTURE: %-18s %-26s %-11s %.2f %.2f  %s" % [
			r["intent"], r["clip"], r["cat"], r["min"], r["mean"], r["posture"]])

	print("POSTURE: ---- grounded clips, which are the ones that read as a dive ----")
	for r in rows:
		if r["posture"] == "GROUNDED":
			print("POSTURE:   %-18s %-26s (%s)" % [r["intent"], r["clip"], r["cat"]])
	quit()


## Hips height across the window the game actually plays, relative to the
## rig's own standing rest height.
func _measure(clip: String, start: float, tail: float) -> Dictionary:
	var path: String = "%s/%s.fbx" % [CLIP_DIR, clip]
	if not ResourceLoader.exists(path):
		return {}
	var packed: PackedScene = load(path)
	if packed == null:
		return {}
	var inst: Node = packed.instantiate()
	root.add_child(inst)
	var skel: Skeleton3D = _find(inst)
	var ap: AnimationPlayer = _find_ap(inst)
	if skel == null or ap == null or ap.get_animation_list().is_empty():
		inst.queue_free()
		return {}

	var hips: int = skel.find_bone("Hips")
	if hips < 0:
		inst.queue_free()
		return {}
	var rest_h: float = skel.get_bone_global_rest(hips).origin.y
	if rest_h < 0.0001:
		inst.queue_free()
		return {}

	var name: String = ap.get_animation_list()[0]
	var anim: Animation = ap.get_animation(name)
	ap.play(name)
	var from: float = 0.0 if start == AnimationSet.WIND_UP else start
	var to: float = minf(anim.length, from + tail)
	var steps: int = maxi(2, int((to - from) * SAMPLE_HZ))
	var lo := INF
	var sum := 0.0
	for i in range(steps):
		ap.seek(from + (to - from) * float(i) / float(steps - 1), true)
		var y: float = _global_pose(skel, hips).origin.y / rest_h
		lo = minf(lo, y)
		sum += y
	root.remove_child(inst)
	inst.queue_free()

	var posture := "UPRIGHT"
	if lo < GROUNDED_FRAC:
		posture = "GROUNDED"
	elif lo < CROUCH_FRAC:
		posture = "CROUCH"
	return {"min": lo, "mean": sum / steps, "posture": posture}


## See tests/diag_anim_inventory.gd: get_bone_global_pose()'s cache is only
## refreshed by a running tree, so compose from the local poses.
func _global_pose(skel: Skeleton3D, bone: int) -> Transform3D:
	var t := Transform3D()
	var i := bone
	while i >= 0:
		t = skel.get_bone_pose(i) * t
		i = skel.get_bone_parent(i)
	return t


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
