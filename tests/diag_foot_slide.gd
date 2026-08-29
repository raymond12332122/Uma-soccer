extends SceneTree

## v0.9.2: how fast does a RENDERED character's gait actually carry it, and
## which way does it face? (brief sections 7 and 18)
##
## Two numbers the integration cannot guess:
##
## 1. RENDERED_NATURAL_SPEED. The pack's jog covers 2.64 m/s on the Mixamo
##    skeleton, but the game plays it on an Uma rig that has been retargeted
##    and then scaled to a 1.6m target height, so the stride the player
##    actually sees is a different length. Playback rate is ground speed
##    divided by this number, so using the pack figure would slide every
##    player by the ratio between the two rigs' proportions.
##
## 2. MODEL_YAW_OFFSET_DEGREES. The game's convention is that a player facing
##    forward faces +Z. If the pack's forward jog carries the hips along -Z
##    instead, every character runs backwards -- visible instantly on screen
##    and invisible in code. Measured here rather than eyeballed.
##
## Method: build the real AnimationController for each character exactly as a
## match does, then drive the locomotion clip by hand and integrate how far
## the PLANTED foot slides backwards under the body. A foot in contact with
## the ground should be stationary in the world while the body moves over it;
## whatever it does instead is the slide.
##
## Run: godot --headless --path . --script tests/diag_foot_slide.gd

const CHAR_DIR := "res://assets/characters"
const CLIP := "res://assets/animations/source/jog forward.fbx"
const SAMPLE_HZ := 60.0

## A foot slower than this (relative to the slowest foot that frame) is the
## one taking the body's weight.
const TARGET_HEIGHT := 1.6


func _initialize() -> void:
	# The pack's own rest orientation, for comparison. If the animation source
	# and the characters agree, the offset is a property of the humanoid
	# profile's reference pose that both were rewritten to, and one display
	# yaw fixes every character. If they DISAGREE, the clips are being played
	# on rigs facing the other way and the retarget config is wrong.
	var pack: Skeleton3D = _pack_skeleton()
	if pack != null:
		var pf: Vector3 = _rest_forward(pack)
		print("FOOT: animation pack rest faces %+.0f deg from +Z" % rad_to_deg(atan2(pf.x, pf.z)))

	_report_directions()

	print("FOOT: character | height_raw | scale | stride_m | cycle_s | natural_m/s | fwd_axis")
	var speeds: Array = []
	for c in _dirs(CHAR_DIR):
		var row: Dictionary = _measure(c)
		if row.is_empty():
			print("FOOT: %-16s FAILED" % c)
			continue
		speeds.append(row["speed"])
		print("FOOT: %-16s | %9.3f | %5.3f | %8.3f | %7.3f | %11.3f | %s" % [
			c, row["height"], row["scale"], row["stride"], row["cycle"],
			row["speed"], row["axis"]])

	if speeds.is_empty():
		quit(); return
	speeds.sort()
	var sum := 0.0
	for s in speeds:
		sum += s
	var mean: float = sum / speeds.size()
	print("FOOT: ---- rendered natural speed: mean %.3f m/s, min %.3f, max %.3f, spread %.1f%% ----" % [
		mean, speeds[0], speeds[-1], 100.0 * (speeds[-1] - speeds[0]) / maxf(mean, 0.001)])
	print("FOOT: set AnimationSet.RENDERED_NATURAL_SPEED to %.2f" % mean)

	# What the game's own speeds imply for playback rate, so the report can
	# state the residual slide instead of implying there is none.
	for label in [["walk", 2.0], ["base run", 5.0], ["sprint", 8.5]]:
		var want: float = label[1]
		var raw: float = want / mean
		var used: float = clampf(raw, AnimationSet.RATE_MIN, AnimationSet.RATE_MAX)
		var shown: float = used * mean
		print("FOOT: %-9s wants %.1f m/s -> rate %.2f, clamped to %.2f -> feet cycle for %.2f m/s, slide %+.2f m/s (%+.0f%%)" % [
			label[0], want, raw, used, shown, want - shown, 100.0 * (want - shown) / want])
	quit()


func _measure(char_name: String) -> Dictionary:
	var scene: PackedScene = load("%s/%s/%s.glb" % [CHAR_DIR, char_name, char_name])
	if scene == null:
		return {}
	var inst: Node3D = scene.instantiate()
	root.add_child(inst)

	var skel: Skeleton3D = _find(inst)
	if skel == null:
		inst.queue_free()
		return {}

	# Same normalisation the controller applies, and APPLIED, so every number
	# below is measured in world metres on the shipped article rather than in
	# whatever units the rig happens to use. That matters more than it looks:
	# these skeletons put the hips 0.12 units off the floor while their mesh
	# AABBs are ~21 units tall, so bone-space distances are meaningless until
	# they have been through the node transforms.
	var raw_height: float = _measure_height(inst)
	var scale: float = TARGET_HEIGHT / raw_height if raw_height > 0.01 else 1.0
	inst.scale = Vector3.ONE * scale
	inst.force_update_transform()

	# Drive the clip through an AnimationPlayer parented so its track paths
	# ('Skeleton3D:<bone>') resolve, exactly as the AnimationTree does.
	var clip: Animation = _clip()
	if clip == null:
		inst.queue_free()
		return {}
	var lib := AnimationLibrary.new()
	lib.add_animation("jog", clip)
	var ap := AnimationPlayer.new()
	skel.get_parent().add_child(ap)
	ap.add_animation_library("", lib)
	ap.root_node = ap.get_path_to(skel.get_parent())
	ap.play("jog")

	var hips: int = skel.find_bone("Hips")
	var lfoot: int = skel.find_bone("LeftFoot")
	var rfoot: int = skel.find_bone("RightFoot")
	if hips < 0 or lfoot < 0 or rfoot < 0:
		inst.queue_free()
		return {}

	var steps: int = maxi(2, int(clip.length * SAMPLE_HZ))
	var dt: float = clip.length / float(steps - 1)
	var prev_l := Vector3.ZERO
	var prev_r := Vector3.ZERO
	var stride := Vector3.ZERO
	# Bone space is NOT render space on these rigs. The Skeleton3D node sits at
	# scale 1 and its bones span 0.16 units head to foot, while the mesh AABB
	# is 18 units tall -- because the skin's bind poses carry a 0.01 scale, so
	# a bone-space distance is one hundredth of the corresponding mesh-space
	# one. Measuring without this reported a 3cm jog stride and would have set
	# the playback rate about eighty times too high.
	var bind_scale: float = _bind_scale(skel)
	# The full chain, not just the scale: Sketchfab's export nests the
	# skeleton four levels down and those parents carry rotations. Skipping
	# them would answer the "which way does it face" question in the wrong
	# frame, which is the one question that has to be right.
	var skel_xform: Transform3D = skel.global_transform.scaled_local(
		Vector3.ONE / maxf(bind_scale, 0.000001))
	# Reported in the MODEL's own frame, because that is the frame
	# AnimationController resolves velocity in.
	var to_model: Basis = inst.global_transform.basis.orthonormalized().inverse()
	for i in range(steps):
		ap.seek(dt * i, true)
		var l: Vector3 = skel_xform * _global_pose(skel, lfoot).origin
		var r: Vector3 = skel_xform * _global_pose(skel, rfoot).origin
		if i > 0:
			# The planted foot is the one moving LESS this frame; the body
			# advances by however far that foot slid backwards under it.
			# Compared on the GROUND PLANE only, so a foot lifting straight up
			# during swing is not mistaken for the one taking the weight.
			var dl := Vector3(l.x - prev_l.x, 0.0, l.z - prev_l.z)
			var dr := Vector3(r.x - prev_r.x, 0.0, r.z - prev_r.z)
			stride -= dl if dl.length() < dr.length() else dr
		prev_l = l
		prev_r = r

	# STRIDE comes from the feet, not from the hips track.
	#
	# The obvious measure -- how far the clip carries the hips -- cannot be
	# used on these rigs. Retargeting normalises position tracks against the
	# source skeleton's proportions and rescales them onto the target, and
	# that rescaling does not survive a skin with a 0.01 bind scale: the
	# applied hips translation comes out around 24m per cycle on a 1.6m
	# character, roughly twenty times its own body height. (Vertically it is
	# fine, because the Y track sits at the rest height and only varies by a
	# few centimetres, which is why the bob is kept and looks right.)
	#
	# That is a second, independent reason to strip the horizontal hips track
	# in AnimationLibraryCache beyond the design argument in section 3: on
	# this rig it is not merely unwanted, it is wrong. The legs are driven by
	# ROTATION tracks, which retarget cleanly, so integrating the planted foot
	# measures the real gait and never touches the broken channel.
	var ground: Vector3 = to_model * stride
	ground.y = 0.0

	# FACING comes from the retargeted REST POSE, which is what the clips are
	# authored against. The shoulder line gives it directly: from the vector
	# pointing at the character's left, forward is up x left. Reading it off
	# the gait instead reported a consistent 23-degree skew on every
	# character, which is the lateral wobble of the footfalls rather than
	# anything about which way the character looks.
	var facing: Vector3 = to_model * _rest_forward(skel)
	var axis: String = "%+.0f deg from +Z" % rad_to_deg(atan2(facing.x, facing.z))

	var out := {
		"height": raw_height,
		"scale": scale,
		"stride": ground.length(),
		"cycle": clip.length,
		"speed": ground.length() / maxf(clip.length, 0.001),
		"axis": axis,
	}
	root.remove_child(inst)
	inst.queue_free()
	return out


## The locomotion clip exactly as the game ships it, so the stride measured
## is the stride the player will see.
func _clip() -> Animation:
	var lib: AnimationLibrary = AnimationLibraryCache.get_library()
	if lib == null:
		return null
	var key: String = AnimationLibraryCache._key("jog forward")
	return lib.get_animation(key) if lib.has_animation(key) else null


## Which way the retargeted REST POSE looks, in skeleton space. Derived from
## the shoulder line rather than from any single bone's basis, because a bone
## basis after silhouette fixing points along the bone, not along the body.
##
## left CROSS up, not up cross left. In a right-handed Y-up system
## right = forward x up, so left = up x forward, and therefore
## forward = left x up. Written the other way round this returns the exact
## opposite and reports every character as facing backwards -- which it did,
## consistently enough across all eleven and the pack to look like a real
## finding rather than a sign error.
static func _rest_forward(skel: Skeleton3D) -> Vector3:
	var to_left: Vector3 = _rest_left(skel)
	if to_left.length() < 0.0001:
		return Vector3.BACK
	return to_left.cross(Vector3.UP).normalized()


static func _find_ap(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r: AnimationPlayer = _find_ap(c)
		if r != null:
			return r
	return null


## Uniform scale baked into the skin's bind poses, i.e. how much smaller bone
## space is than the mesh space the character is actually drawn in.
static func _bind_scale(skel: Skeleton3D) -> float:
	for c in skel.get_children():
		var mi := c as MeshInstance3D
		if mi != null and mi.skin != null and mi.skin.get_bind_count() > 0:
			return mi.skin.get_bind_pose(0).basis.get_scale().y
	return 1.0


## See tests/diag_anim_inventory.gd: Skeleton3D.get_bone_global_pose()'s cache
## is only refreshed by a running tree, so compose from the local poses the
## AnimationPlayer writes directly.
func _global_pose(skel: Skeleton3D, bone: int) -> Transform3D:
	var t := Transform3D()
	var i := bone
	while i >= 0:
		t = skel.get_bone_pose(i) * t
		i = skel.get_bone_parent(i)
	return t


func _measure_height(root_node: Node) -> float:
	var aabb := AABB()
	var first := true
	var stack: Array = [root_node]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D and node.mesh:
			var a: AABB = (node as MeshInstance3D).global_transform * node.mesh.get_aabb()
			if first:
				aabb = a
				first = false
			else:
				aabb = aabb.merge(a)
		for c in node.get_children():
			stack.append(c)
	return aabb.size.y


func _find(n: Node) -> Skeleton3D:
	if n is Skeleton3D: return n
	for c in n.get_children():
		var r: Skeleton3D = _find(c)
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


func _pack_skeleton() -> Skeleton3D:
	var packed: PackedScene = load(CLIP)
	return _find(packed.instantiate()) if packed != null else null


## Where each locomotion clip actually carries the character, in the RIG's own
## left/right/forward frame (brief section 6).
##
## This is measured rather than read off the filenames because the frame the
## filenames are written in is not obvious, and getting it wrong puts the
## strafe-left clip on the strafe-right blend point -- a mistake that is
## invisible in code and unmistakable on screen. Both axes come from the
## retargeted rest pose: forward from the shoulder line, right as its
## opposite. Directions carry the ~23 degree footfall wobble noted above,
## which is far inside the 45 degrees separating adjacent blend points.
func _report_directions() -> void:
	var scene: PackedScene = load("%s/gold_ship/gold_ship.glb" % CHAR_DIR)
	if scene == null:
		return
	var inst: Node3D = scene.instantiate()
	root.add_child(inst)
	var skel: Skeleton3D = _find(inst)
	if skel == null:
		inst.queue_free()
		return

	var fwd: Vector3 = _rest_forward(skel)
	var left: Vector3 = _rest_left(skel)
	var lib: AnimationLibrary = AnimationLibraryCache.get_library()
	var ap := AnimationPlayer.new()
	skel.get_parent().add_child(ap)
	ap.add_animation_library("", lib)
	ap.root_node = ap.get_path_to(skel.get_parent())

	print("FOOT: ---- locomotion travel in the rig's own frame (right, forward) ----")
	for clip in AnimationSet.LOCOMOTION:
		var key: String = AnimationLibraryCache._key(clip)
		if not lib.has_animation(key):
			continue
		var d: Vector3 = _travel_of(skel, ap, key)
		if d.length() < 0.0001:
			continue
		d = d.normalized()
		var right_c: float = -left.dot(d)
		var fwd_c: float = fwd.dot(d)
		print("FOOT:   %-26s right %+.2f  forward %+.2f   (%+.0f deg)" % [
			clip, right_c, fwd_c, rad_to_deg(atan2(right_c, fwd_c))])
	root.remove_child(inst)
	inst.queue_free()


## Ground travel of one clip, from the planted foot, in skeleton space.
func _travel_of(skel: Skeleton3D, ap: AnimationPlayer, key: String) -> Vector3:
	var anim: Animation = ap.get_animation(key)
	ap.play(key)
	var steps: int = maxi(2, int(anim.length * SAMPLE_HZ))
	var dt: float = anim.length / float(steps - 1)
	var lf: int = skel.find_bone("LeftFoot")
	var rf: int = skel.find_bone("RightFoot")
	var prev_l := Vector3.ZERO
	var prev_r := Vector3.ZERO
	var sum := Vector3.ZERO
	for i in range(steps):
		ap.seek(dt * i, true)
		var l: Vector3 = _global_pose(skel, lf).origin
		var r: Vector3 = _global_pose(skel, rf).origin
		if i > 0:
			var dl := Vector3(l.x - prev_l.x, 0.0, l.z - prev_l.z)
			var dr := Vector3(r.x - prev_r.x, 0.0, r.z - prev_r.z)
			sum -= dl if dl.length() < dr.length() else dr
		prev_l = l
		prev_r = r
	return sum


## Direction of the character's LEFT, from the retargeted rest pose.
static func _rest_left(skel: Skeleton3D) -> Vector3:
	var l: int = skel.find_bone("LeftUpperArm")
	var r: int = skel.find_bone("RightUpperArm")
	if l < 0 or r < 0:
		return Vector3.LEFT
	var v: Vector3 = skel.get_bone_global_rest(l).origin - skel.get_bone_global_rest(r).origin
	v.y = 0.0
	return v.normalized() if v.length() > 0.0001 else Vector3.LEFT
