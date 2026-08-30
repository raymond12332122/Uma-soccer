extends Node3D

## v0.9.2.1: find the object that keeps appearing on screen (brief section 1).
##
## Human QA reports a large artifact obstructing gameplay, appearing very
## frequently, while moving and while standing still. The brief is explicit:
## do not guess, isolate.
##
## A "large object" in a skinned-character game is almost always a mesh whose
## vertices have been dragged somewhere they should not be, and vertices go
## where their BONES go. So rather than staring at frames, this watches every
## bone of every animated player every physics frame and reports any that
## leaves a sane envelope -- which names the character, the clip, the state
## and the bone, instead of a hypothesis.
##
## It measures three separate things, because they fail differently:
##
##   1. bone distance from the skeleton origin, against the rig's own rest
##      extent. A bone at 20x its rest distance IS the giant triangle.
##   2. the hips vertical channel specifically. v0.9.2 established that
##      retargeting mis-scales position tracks on these rigs by roughly 20x
##      and stripped the horizontal part; the vertical part was checked on
##      ONE clip and kept. If that check did not generalise, every clip with
##      a crouch or a dive in it launches the character.
##   3. non-finite transforms, which produce whole-screen garbage.
##
## Run headless -- bones do not need a renderer:
##   godot --headless --path . tests/DiagArtifactHunt.tscn

const MainScene := preload("res://scenes/Main.tscn")
const SECONDS := 40

## A bone further from the skeleton origin than this multiple of the rig's own
## rest extent is not where a body part belongs.
const OUTLIER_FACTOR := 3.0

var _worst := {}
var _events: Array = []
var _frames := 0


func _ready() -> void:
	print("HUNT: ==== scanning every bone of every animated player ====")
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(90):
		await get_tree().physics_frame

	var players: Array = main.home_players + main.away_players
	var rigs: Array = []
	for p in players:
		var ac: AnimationController = p.animation_controller
		if ac == null or not ac.is_animated():
			continue
		var skel: Skeleton3D = _find_skel(ac)
		if skel == null:
			continue
		rigs.append({
			"player": p,
			"skel": skel,
			"tree": ac.get_node_or_null("AnimationTree"),
			"ac": ac,
			"rest": _rest_extent(skel),
			"hips": skel.find_bone("Hips"),
		})
	print("HUNT: watching %d rigs; rest extent %.4f to %.4f (skeleton units)" % [
		rigs.size(), _min_rest(rigs), _max_rest(rigs)])

	for i in range(SECONDS * 60):
		await get_tree().physics_frame
		_frames += 1
		for r in rigs:
			_scan(r)

	_report()
	get_tree().quit()


func _scan(r: Dictionary) -> void:
	var skel: Skeleton3D = r["skel"]
	var rest: float = r["rest"]
	var limit: float = rest * OUTLIER_FACTOR
	var count: int = skel.get_bone_count()
	for b in range(count):
		var t: Transform3D = skel.get_bone_global_pose(b)
		var o: Vector3 = t.origin
		if not (is_finite(o.x) and is_finite(o.y) and is_finite(o.z)):
			_note(r, skel.get_bone_name(b), INF, "NON-FINITE")
			continue
		var d: float = o.length()
		if d > limit:
			_note(r, skel.get_bone_name(b), d / maxf(rest, 0.0001), "far")

	# The hips vertical channel on its own: it is the one position track kept.
	var hips: int = r["hips"]
	if hips >= 0:
		var y: float = skel.get_bone_global_pose(hips).origin.y
		var ratio: float = y / maxf(rest, 0.0001)
		var key: String = "hips_y"
		var prev: float = _worst.get(key, {}).get("value", -INF)
		if ratio > prev:
			_worst[key] = {"value": ratio, "who": r["player"].name, "state": _state_of(r)}
		if ratio > 2.0 or ratio < -0.5:
			_note(r, "Hips", ratio, "hips Y out of band")


func _note(r: Dictionary, bone: String, magnitude: float, why: String) -> void:
	var key: String = "%s|%s" % [bone, why]
	var e: Dictionary = _worst.get(key, {"value": -INF, "count": 0})
	e["count"] = e.get("count", 0) + 1
	if magnitude > e["value"]:
		e["value"] = magnitude
		e["who"] = r["player"].name
		e["visual"] = r["player"].player_data.visual_id if r["player"].player_data else "?"
		e["state"] = _state_of(r)
		e["last_action"] = r["ac"].last_action
	_worst[key] = e


## What the AnimationTree is doing right now, so an outlier names its cause.
func _state_of(r: Dictionary) -> String:
	var tree: AnimationTree = r["tree"]
	if tree == null:
		return "no tree"
	var acting: bool = tree.get("parameters/Shot/active")
	return "%s blend=%s amt=%.2f rate=%.2f" % [
		("ACTION:" + str(r["ac"].last_action)) if acting else "locomotion",
		tree.get("parameters/Move/blend_position"),
		float(tree.get("parameters/Loco/blend_amount")),
		float(tree.get("parameters/MoveScale/scale"))]


func _report() -> void:
	print("HUNT: ---- %d frames scanned ----" % _frames)
	var keys: Array = _worst.keys()
	keys.sort()
	var found := false
	for k in keys:
		var e: Dictionary = _worst[k]
		if k == "hips_y":
			print("HUNT: peak hips height %.2fx rest on %s (%s)" % [
				e["value"], e.get("who", "?"), e.get("state", "?")])
			continue
		found = true
		print("HUNT: !! %-28s %6d frames, worst %.1fx rest on %s (%s) state=%s" % [
			k, e["count"], e["value"], e.get("who", "?"), e.get("visual", "?"), e.get("state", "?")])
	if not found:
		print("HUNT: no bone left its envelope -- the artifact is NOT a flung bone")


func _rest_extent(skel: Skeleton3D) -> float:
	var m := 0.0
	for b in range(skel.get_bone_count()):
		m = maxf(m, skel.get_bone_global_rest(b).origin.length())
	return m


func _min_rest(rigs: Array) -> float:
	var m := INF
	for r in rigs:
		m = minf(m, r["rest"])
	return m


func _max_rest(rigs: Array) -> float:
	var m := 0.0
	for r in rigs:
		m = maxf(m, r["rest"])
	return m


func _find_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var r: Skeleton3D = _find_skel(c)
		if r != null:
			return r
	return null
