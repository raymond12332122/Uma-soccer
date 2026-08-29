extends SceneTree

## v0.9.2: inventory and MEASURE every clip in the pack (brief sections 1, 7, 9, 10).
##
## The filename says "kick soccerball". It does not say how long the clip is,
## how fast the character is travelling while it plays, or which frame the
## boot meets the ball on -- and those are exactly the numbers the integration
## needs. A locomotion clip played at the wrong rate slides; a kick clip
## triggered at the wrong offset launches the ball before or after the leg
## swings. So this samples the actual retargeted pose rather than reading
## filenames or track metadata.
##
## Per clip it reports:
##   dur/loop/tracks   what the importer produced
##   travel            how far the hips move across the clip, and the implied
##                     natural ground speed -- section 7's input for playback
##                     rate, and the reason a clip with travel ~0 must never
##                     be used as a locomotion state
##   contact           the time of PEAK foot speed relative to the hips, and
##                     which foot. For a strike clip that is the frame the
##                     foot is driving through the ball, so it is the offset
##                     a gameplay launch should be aligned to (section 9/10).
##   planted           fraction of the clip each foot spends near-stationary
##                     against the ground; a locomotion clip alternates, a
##                     clip that never plants a foot is not a gait.
##
## Sampling is done by seeking a real AnimationPlayer and reading the
## Skeleton3D's global bone poses, because after retargeting the position
## tracks for everything but the hips are gone -- there is nothing left to
## read off the Animation resource directly.
##
## Run: godot --headless --path . --script tests/diag_anim_inventory.gd

const SOURCE_DIR := "res://assets/animations/source"
const SAMPLE_HZ := 60.0

## A foot moving slower than this against the ground is taken as planted.
const PLANTED_SPEED := 0.35


func _initialize() -> void:
	var files: Array = _files(SOURCE_DIR, ".fbx")
	print("ANIM-INV: %d source files" % files.size())
	print("ANIM-INV: clip | dur | loop | tracks | travel_m | nat_speed | contact_t | foot | plantedL | plantedR")

	var rows: Array = []
	var failed: Array = []
	for f in files:
		var row: Dictionary = _measure(f)
		if row.is_empty():
			failed.append(f.get_file())
			continue
		rows.append(row)
		print("ANIM-INV: %-32s | %5.2fs | %-4s | %3d | %6.2f | %5.2f | %5.2f | %-5s | %.2f | %.2f" % [
			row["clip"], row["dur"], row["loop"], row["tracks"],
			row["travel"], row["speed"], row["contact_t"], row["contact_foot"],
			row["planted_l"], row["planted_r"]])

	# Which way does each clip actually travel? Mixamo gives the two forward
	# diagonals identical names -- 'jog forward diagonal' and '... (2)' -- so
	# left and right can only be told apart by measuring. Guessing would put
	# the left-diagonal clip on the right-diagonal blend point, which is
	# invisible in code review and permanently wrong on screen. Angles are
	# reported RELATIVE TO 'jog forward', so no assumption about which world
	# axis Mixamo calls forward is needed.
	var fwd := Vector2.ZERO
	for r in rows:
		if r["clip"] == "jog forward":
			fwd = r["travel_vec"].normalized()
	print("ANIM-INV: ---- travel direction, degrees relative to 'jog forward' (+ = toward the character's LEFT-hand side of that axis) ----")
	for r in rows:
		if r["travel"] < 0.30 or fwd == Vector2.ZERO:
			continue
		var v: Vector2 = r["travel_vec"].normalized()
		var ang: float = rad_to_deg(atan2(fwd.x * v.y - fwd.y * v.x, fwd.dot(v)))
		print("ANIM-INV:   %-32s %7.1f deg  (%.2f m over %.2fs)" % [
			r["clip"], ang, r["travel"], r["dur"]])

	print("ANIM-INV: ---- summary ----")
	var moving := 0
	var still := 0
	for r in rows:
		if r["travel"] > 0.30:
			moving += 1
		else:
			still += 1
	print("ANIM-INV: %d clips measured, %d failed" % [rows.size(), failed.size()])
	print("ANIM-INV: %d travel across the ground (>0.30m), %d stay in place" % [moving, still])
	if not failed.is_empty():
		print("ANIM-INV: failed: %s" % ", ".join(failed))
	quit()


func _measure(path: String) -> Dictionary:
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

	var clip_name: String = ap.get_animation_list()[0]
	var anim: Animation = ap.get_animation(clip_name)
	var hips: int = skel.find_bone("Hips")
	var lfoot: int = skel.find_bone("LeftFoot")
	var rfoot: int = skel.find_bone("RightFoot")
	if hips < 0 or lfoot < 0 or rfoot < 0:
		inst.queue_free()
		return {}

	ap.play(clip_name)
	var steps: int = maxi(2, int(anim.length * SAMPLE_HZ))
	var dt: float = anim.length / float(steps - 1)

	var hips_pos: Array = []
	var lf_pos: Array = []
	var rf_pos: Array = []
	for i in range(steps):
		ap.seek(dt * i, true)
		hips_pos.append(_global_pose(skel, hips).origin)
		lf_pos.append(_global_pose(skel, lfoot).origin)
		rf_pos.append(_global_pose(skel, rfoot).origin)

	var travel_vec := Vector2(
		hips_pos[steps - 1].x - hips_pos[0].x,
		hips_pos[steps - 1].z - hips_pos[0].z)
	var travel: float = travel_vec.length()

	# Contact candidate: peak foot speed measured RELATIVE TO THE HIPS, so a
	# clip that also travels does not read its own forward motion as a strike.
	var best_speed := 0.0
	var best_t := 0.0
	var best_foot := "-"
	# Planted: a foot near-stationary against the ground (skeleton space, which
	# is the ground here since the skeleton node itself never moves).
	var planted_l := 0
	var planted_r := 0
	for i in range(1, steps):
		var l_rel: float = ((lf_pos[i] - hips_pos[i]) - (lf_pos[i - 1] - hips_pos[i - 1])).length() / dt
		var r_rel: float = ((rf_pos[i] - hips_pos[i]) - (rf_pos[i - 1] - hips_pos[i - 1])).length() / dt
		if l_rel > best_speed:
			best_speed = l_rel
			best_t = dt * i
			best_foot = "left"
		if r_rel > best_speed:
			best_speed = r_rel
			best_t = dt * i
			best_foot = "right"
		if (lf_pos[i] - lf_pos[i - 1]).length() / dt < PLANTED_SPEED:
			planted_l += 1
		if (rf_pos[i] - rf_pos[i - 1]).length() / dt < PLANTED_SPEED:
			planted_r += 1

	var row := {
		"clip": path.get_file().replace(".fbx", ""),
		"dur": anim.length,
		"loop": "loop" if anim.loop_mode != Animation.LOOP_NONE else "once",
		"tracks": anim.get_track_count(),
		"travel": travel,
		"travel_vec": travel_vec,
		"speed": travel / maxf(anim.length, 0.001),
		"contact_t": best_t,
		"contact_speed": best_speed,
		"contact_foot": best_foot,
		"planted_l": float(planted_l) / float(steps - 1),
		"planted_r": float(planted_r) / float(steps - 1),
	}
	root.remove_child(inst)
	inst.queue_free()
	return row


## Compose a bone's global pose from local poses by walking up to the root.
##
## Skeleton3D.get_bone_global_pose() would be the obvious call, but its cache
## is only refreshed while the skeleton is being processed by a running tree.
## In a headless tool that seeks an AnimationPlayer by hand it returns the
## rest pose forever -- which reads as "every clip is perfectly still" rather
## than as an error, so the first version of this tool silently reported 0.00
## travel for all 54 clips. get_bone_pose() is written directly by the
## AnimationPlayer and is always current, so compose from that instead.
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
