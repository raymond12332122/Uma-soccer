class_name AnimationController
extends Node3D

## Bridges FootballPlayer's gameplay state to whatever visual character is
## currently assigned via PlayerData.visual_id. FootballPlayer only ever
## talks to this narrow interface:
##
##   set_visual(visual_id)   -- (re)builds the displayed character
##   set_state(state)        -- continuous locomotion/possession state
##   set_motion(velocity)    -- the body's actual ground velocity
##   play_action(action)     -- one-shot gameplay intent
##   set_team_color(color)   -- team tint (placeholder capsule only; a
##                              real character keeps its authored textures)
##
## Every one of those is an INTENT. No call site anywhere names a clip, picks
## a blend weight or sets a playback rate; this file owns all of that, and
## AnimationSet owns which clip an intent resolves to. That boundary is the
## point of brief section 4: gameplay says "pass", not "play kick_03".
##
## v0.9.2 puts a real AnimationTree behind that interface:
##
##   Idle ------\
##               Blend2 (Loco) ---\
##   Move -> TimeScale -/          OneShot (Shot) --> output
##   Action ----------------------/
##
## Move is an eight-point directional blend space driven by the CharacterBody's
## own velocity, expressed in the model's local frame. TimeScale sets playback
## rate from ground speed so the feet keep up. OneShot layers a gameplay
## action over the top and takes itself off again when the clip ends, which is
## what makes "one gameplay contact, one animation" true by construction
## rather than by bookkeeping (section 8).
##
## GAMEPLAY REMAINS AUTHORITATIVE. Nothing here writes to the CharacterBody,
## the ball, or any gameplay state; the ground travel baked into the clips is
## removed at library build time (see AnimationLibraryCache). The animation
## layer reads the simulation and never the other way round.
##
## If the pack is unavailable, or the visual is the placeholder capsule, this
## falls back to the lightweight procedural motion it used before v0.9.2, so
## the game is never silently static (section 24).

@export var target_height: float = 1.6
## Extra correction if a model's own "front" doesn't already face +Z after
## import (this project's forward convention). 0 = no correction needed --
## true for the model shipped in v0.4, verified against its rig data.
@export var facing_correction_degrees: float = 0.0

## Kept for the procedural fallback path only. With real clips loaded, states
## are resolved through the blend space from measured velocity instead.
const PULSE_DURATIONS := {
	"pass": 0.3,
	"shoot": 0.4,
	"celebration": 0.9,
	"tackle": 0.4,
	"look_around": 0.8,
	"excited_reaction": 0.7,
	"frustrated_reaction": 0.6,
	"victory_pose": 1.3,
}

var _visual_root: Node3D = null
var _tree: AnimationTree = null
var _action_node: AnimationNodeAnimation = null
var _uses_real_model: bool = false
## True once the AnimationTree is built and driving a real skeleton.
var _animated: bool = false
var _is_keeper: bool = false
## Which half of the clip database this player may draw from.
var _role: int = AnimationSet.Role.OUTFIELD
## Rotates the clip picked for intents that offer more than one.
var _variant_turn: int = 0
## Ground speed this character's gait covers at 1x playback, in m/s. Measured
## per rig (see AnimationSet); the roster mean until a visual is assigned.
var _natural_speed: float = AnimationSet.RENDERED_NATURAL_SPEED

var _current_state: String = "idle"
var _motion := Vector3.ZERO
var _procedural_time: float = 0.0
var _pulse_kind: String = ""
var _pulse_time: float = -1.0

## Diagnostic only (read by tests/tools) -- the height measured before the
## auto-fit scale was applied, in whatever units the source file used.
var last_measured_height: float = 0.0

## Diagnostic only (read by tests) -- true once _fix_tpose_arms() has run
## for the current real-model visual (see _setup_real_model).
var t_pose_fixed: bool = false

## How far past the skeleton's rest extent the render bounds are grown, as a
## fraction of the rig's height. A dive throws a keeper's arm well clear of
## anything in the rest pose, and hair, skirts and tails are not mapped bones.
const BOUNDS_MARGIN := 0.30

## Diagnostic only (read by tests) -- the bounds handed to the renderer for
## the current visual, in skeleton-local units. See _fix_render_bounds().
var last_render_bounds := AABB()

## Test-only lever: skip the render-bounds correction, restoring the v0.9.2
## behaviour. It exists so the artifact fix can be demonstrated as a
## controlled A/B on the same seeded match rather than by comparing two
## screenshots from different runs. Never set in shipped code.
static var force_legacy_bounds := false

## Diagnostic only -- how many action clips this controller has fired, and
## the last intent it resolved. The v0.9.2 tests assert one contact produces
## exactly one of these.
var actions_fired: int = 0
var last_action: String = ""

## Diagnostic only -- how many intents were refused because they belong to the
## other role, and the last one. In a correct build these stay at zero; the
## v0.9.2.1 suite asserts it, so a role leak fails a test instead of showing
## up as a striker diving.
var refusals: int = 0
var last_refusal: String = ""

## Relaxed-hang target direction for the upper arm bone, in skeleton-local
## space (Y-up, confirmed empirically for every currently-integrated
## model). X is mirrored per side; a small outward/forward bias keeps the
## arm from clipping straight through the torso.
const _TPOSE_UPPER_ARM_TARGET := Vector3(0.18, -1.0, 0.08)


func set_visual(visual_id: String) -> void:
	if _visual_root:
		_visual_root.queue_free()
	if _tree:
		_tree.queue_free()
	_visual_root = null
	_tree = null
	_action_node = null
	_animated = false
	_pulse_kind = ""
	_pulse_time = -1.0
	t_pose_fixed = false

	_natural_speed = AnimationSet.natural_speed(visual_id)
	var scene: PackedScene = CharacterRegistry.get_scene(visual_id)
	if scene:
		_uses_real_model = true
		_setup_real_model(scene)
	else:
		_uses_real_model = false
		_setup_placeholder()


func supports_team_tint() -> bool:
	return not _uses_real_model


## True when a real AnimationTree is driving a real skeleton, i.e. what the
## player is doing is being shown by clips rather than by the procedural
## fallback. Read by tests and by the section 32 counts.
func is_animated() -> bool:
	return _animated


## Goalkeepers idle differently and have their own action vocabulary.
##
## This is the ONE place a player's animation role is decided, and it is
## decided from the gameplay role rather than from anything the animation
## layer knows. Everything else -- which clips are selectable, which idle
## loops, which intents are refused -- follows from it.
func set_keeper(is_keeper: bool) -> void:
	_role = AnimationSet.Role.GOALKEEPER if is_keeper else AnimationSet.Role.OUTFIELD
	if _is_keeper == is_keeper:
		return
	_is_keeper = is_keeper
	if _animated:
		_apply_idle_clip()


func set_team_color(color: Color) -> void:
	if _uses_real_model or _visual_root == null:
		return
	var mesh: MeshInstance3D = _visual_root as MeshInstance3D
	if mesh == null:
		return
	var mat: StandardMaterial3D = mesh.get_surface_override_material(0)
	mat = mat.duplicate() if mat else StandardMaterial3D.new()
	mat.albedo_color = color
	mesh.set_surface_override_material(0, mat)


## The body's actual ground velocity, in world space. Section 5: locomotion is
## driven by what the CharacterBody is really doing, never by what the input
## asked for or by what state machine a designer imagined.
func set_motion(velocity: Vector3) -> void:
	_motion = velocity


## Continuous locomotion/possession state, called every physics frame by
## FootballPlayer. Cheap to call redundantly -- no-ops if unchanged.
##
## With clips loaded this is advisory: the blend space reads velocity, so
## "run" and "sprint" are the same clip at different rates and the state name
## only decides the special cases (a scripted sit, say).
func set_state(state: String) -> void:
	if state == _current_state:
		return
	_current_state = state


## One-shot gameplay intent. `action` is a semantic name from AnimationSet --
## "pass", "shoot", "challenge", "save_left" -- never a clip.
##
## ROLE IS ENFORCED HERE, and it is a refusal rather than a fallback. An
## outfield player asking for "save_left" plays nothing at all and the refusal
## is counted, because the alternative -- quietly substituting a procedural
## pulse -- would hide the bug that human QA reported instead of preventing
## it. A striker must not dive, and if some future call site asks one to, the
## refusal counter says so out loud.
func play_action(action: String) -> void:
	var intent: String = AnimationSet.ALIASES.get(action, action)
	if AnimationSet.INTENTS.has(intent) and not AnimationSet.allowed(intent, _role):
		refusals += 1
		last_refusal = intent
		push_warning("AnimationController: '%s' is not available to this role" % intent)
		return

	if _animated and _action_node != null:
		var entry: Dictionary = AnimationSet.resolve(intent, _role)
		if not entry.is_empty():
			var options: int = entry["clips"].size()
			# Rotate through the variants so repeated events do not look
			# identical. Per controller, so two players side by side are not
			# in lockstep either.
			var pick: int = _variant_turn % options if options > 0 else 0
			_variant_turn += 1
			_action_node.animation = AnimationSet.variant_key(intent, pick)
			var shot := _tree.tree_root.get_node("Shot") as AnimationNodeOneShot
			shot.fadein_time = entry["fade_in"]
			shot.fadeout_time = entry["fade_out"]
			_tree.set("parameters/Shot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
			actions_fired += 1
			last_action = intent
			return

	# No clip for this intent (or no library at all): the procedural pulse
	# still gives the player something to see. Reactions like "celebration"
	# live here permanently -- the pack has nothing for them.
	_pulse_kind = action
	_pulse_time = 0.0
	actions_fired += 1
	last_action = action


func _process(delta: float) -> void:
	if _visual_root == null:
		return
	_procedural_time += delta

	if _animated:
		_drive_tree()
		return

	if _pulse_time >= 0.0:
		_pulse_time += delta
		var duration: float = PULSE_DURATIONS.get(_pulse_kind, 0.4)
		if _pulse_time > duration:
			_pulse_time = -1.0
			_pulse_kind = ""
		else:
			_apply_action_pulse(_pulse_kind, _pulse_time / duration)
			return

	_apply_state_procedural(_current_state)


## Feed the blend space from the body's real velocity.
##
## The velocity is rotated into the MODEL's frame, so the blend point means
## "how much of this is forward and how much is sideways from where the
## character is looking" -- which is what the eight clips actually are. A
## player running north while facing east strafes, and it comes out of this
## without a single special case (section 6).
func _drive_tree() -> void:
	var planar := Vector3(_motion.x, 0.0, _motion.z)
	var speed: float = planar.length()

	# Rotated into the frame the model FACES, taken from this node rather than
	# from the model instance: the instance carries the height-normalisation
	# scale, and inverting a scaled basis is a needless source of error when
	# the parent already holds the clean facing rotation.
	var local: Vector3 = global_transform.basis.orthonormalized().inverse() * planar
	# x is the character's own right (see AnimationSet.MODEL_RIGHT), which is
	# NOT the model's +X.
	var dir := Vector2(AnimationSet.MODEL_RIGHT.x * local.x, local.z)
	if dir.length() > 0.001:
		dir = dir.normalized()
	_tree.set("parameters/Move/blend_position", dir)

	var move_amount: float = clampf(
		(speed - AnimationSet.IDLE_SPEED)
		/ maxf(AnimationSet.FULL_MOVE_SPEED - AnimationSet.IDLE_SPEED, 0.01), 0.0, 1.0)
	_tree.set("parameters/Loco/blend_amount", move_amount)

	# Rate is what keeps the feet with the ground. Clamped: past the top of
	# the band a jog clip stops reading as running, and the game's 8.5 m/s
	# sprint is about three times the clip's natural speed, so the clamp IS
	# reached and sprinting does slide. Measured, reported, not hidden.
	var rate: float = clampf(speed / maxf(_natural_speed, 0.01),
		AnimationSet.RATE_MIN, AnimationSet.RATE_MAX)
	_tree.set("parameters/MoveScale/scale", rate)


func _apply_state_procedural(state: String) -> void:
	var bob_speed := 1.6
	var bob_height := 0.02
	var lean := 0.0

	match state:
		"walk":
			bob_speed = 6.0
			bob_height = 0.05
			lean = 0.03
		"run":
			bob_speed = 9.0
			bob_height = 0.07
			lean = 0.08
		"sprint":
			bob_speed = 11.0
			bob_height = 0.09
			lean = 0.14
		"dribble":
			bob_speed = 8.0
			bob_height = 0.06
			lean = 0.05
		"sitting":
			var sway: float = sin(_procedural_time * 1.2) * 0.015
			_visual_root.position = Vector3(0, -0.55 + sway, 0)
			_visual_root.rotation = Vector3(0.15, 0, 0)
			return

	var bob: float = sin(_procedural_time * bob_speed) * bob_height
	_visual_root.position = Vector3(0, bob, 0)
	_visual_root.rotation = Vector3(lean, 0, 0)


func _apply_action_pulse(kind: String, t: float) -> void:
	var ease_out: float = 1.0 - t
	match kind:
		"pass":
			_visual_root.position = Vector3.ZERO
			_visual_root.rotation = Vector3(-0.25 * ease_out, 0, 0)
		"shoot":
			_visual_root.position = Vector3.ZERO
			_visual_root.rotation = Vector3(-0.4 * ease_out, 0, 0)
		"celebration":
			_visual_root.position = Vector3(0, 0.15 * sin(t * PI), 0)
			_visual_root.rotation = Vector3(0, t * TAU, 0)
		"tackle":
			_visual_root.position = Vector3.ZERO
			_visual_root.rotation = Vector3(0.3 * ease_out, 0, 0)
		"look_around":
			_visual_root.position = Vector3.ZERO
			_visual_root.rotation = Vector3(0, sin(t * TAU * 0.5) * 0.6 * ease_out, 0)
		"excited_reaction":
			_visual_root.position = Vector3(0, absf(sin(t * PI * 3.0)) * 0.12 * ease_out, 0)
			_visual_root.rotation = Vector3.ZERO
		"frustrated_reaction":
			_visual_root.position = Vector3.ZERO
			_visual_root.rotation = Vector3(0, sin(t * PI * 4.0) * 0.15 * ease_out, 0)
		"victory_pose":
			_visual_root.position = Vector3(0, 0.2 * sin(t * PI) * ease_out + 0.1 * sin(t * PI), 0)
			_visual_root.rotation = Vector3(-0.2 * ease_out, t * TAU * 1.5, 0)
		_:
			_visual_root.position = Vector3.ZERO
			_visual_root.rotation = Vector3.ZERO


func _setup_placeholder() -> void:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "PlaceholderMesh"
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.4
	capsule.height = 1.6
	mesh_instance.mesh = capsule
	mesh_instance.position = Vector3(0, 0.8, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.9, 0.9, 1)
	mesh_instance.set_surface_override_material(0, mat)
	add_child(mesh_instance)
	_visual_root = mesh_instance


func _setup_real_model(scene: PackedScene) -> void:
	var instance: Node3D = scene.instantiate()
	add_child(instance)
	_visual_root = instance

	# Downloaded models arrive with wildly inconsistent (and sometimes
	# simply wrong) embedded scale conventions. Rather than trusting that,
	# measure the imported geometry's actual height and normalize it to
	# match the game's calibrated proportions (ball/goal/pitch/camera were
	# all tuned around ~1.6m characters).
	var measured_height: float = _measure_height(instance)
	last_measured_height = measured_height
	if measured_height > 0.01 and measured_height < 1000.0:
		var factor: float = target_height / measured_height
		instance.scale = Vector3.ONE * factor
	else:
		push_warning("AnimationController: could not measure a sane height (%f) for model, leaving scale untouched" % measured_height)

	# Section 18: ONE place decides which way a model faces. The correction is
	# a measured property of the rig plus the pack (see
	# AnimationSet.MODEL_YAW_OFFSET_DEGREES), not a per-character fudge
	# scattered through scene files.
	var yaw: float = facing_correction_degrees + AnimationSet.MODEL_YAW_OFFSET_DEGREES
	if yaw != 0.0:
		instance.rotate_y(deg_to_rad(yaw))

	var skeleton: Skeleton3D = _find_skeleton(instance)
	if skeleton != null:
		_fix_render_bounds(skeleton)
	if skeleton != null and _build_tree(skeleton):
		_animated = true
		return

	# Every currently-integrated model ships in a bind pose (T-pose: arms
	# straight out horizontally), so without this a character with no clips
	# would stand and run around looking like a floating cross. Only reached
	# on the no-clips path -- a driven skeleton poses itself.
	if skeleton:
		_fix_tpose_arms(skeleton)
		t_pose_fixed = true


## Tell the renderer how big this character actually is.
##
## THE v0.9.2 VISUAL ARTIFACT. Every character was reporting a ~190 metre
## bounding volume to the renderer, and the black shapes sweeping across the
## pitch were the directional light's shadow being fitted around them.
##
## A skinned mesh's vertices reach their final position through the SKIN:
## world = bone_global_pose * bind_pose * vertex. On these rigs the mesh
## resources are authored around 21 units tall and the bind pose carries a
## 0.01 scale that brings them back to metres. But an AABB is never skinned.
## Godot bounds a MeshInstance3D by mesh.get_aabb() through the node
## transform, which does not include the bind pose -- so the bounds come out
## 100x too large, and the height-normalisation scale (7.38x here) multiplies
## that again.
##
## It only became visible in v0.9.2 because retargeting's apply_node_transforms
## rebaked the meshes into that 21-unit space; before it they were already in
## metres and the accidental agreement held.
##
## The fix is to state the real bounds rather than to hide anything: the
## skeleton's own rest extent, grown generously so a dive or an outstretched
## leg still falls inside it. Bounds that are too small pop geometry in and
## out at the screen edge, so the margin is deliberate.
func _fix_render_bounds(skeleton: Skeleton3D) -> void:
	if force_legacy_bounds:
		return
	var count: int = skeleton.get_bone_count()
	if count == 0:
		return
	var bounds := AABB(skeleton.get_bone_global_rest(0).origin, Vector3.ZERO)
	for b in range(count):
		bounds = bounds.expand(skeleton.get_bone_global_rest(b).origin)
	# Room for limbs thrown out well past the rest pose (a keeper's dive is
	# the extreme) plus hair, skirts and tails, which are not bones we map.
	bounds = bounds.grow(maxf(bounds.size.y, 0.01) * BOUNDS_MARGIN)
	for child in skeleton.get_children():
		var mi := child as MeshInstance3D
		if mi != null:
			mi.custom_aabb = bounds
	last_render_bounds = bounds


## Build this player's AnimationTree over the shared clip library.
##
## The tree's root_node is the skeleton's PARENT, because the pack's track
## paths are 'Skeleton3D:<bone>' and every character keeps a node called
## Skeleton3D at that level (the retarget config deliberately leaves
## make_unique off for exactly this reason). That is what lets 22 players and
## 11 different rigs share one untouched library instead of each needing its
## own track paths rewritten.
func _build_tree(skeleton: Skeleton3D) -> bool:
	var lib: AnimationLibrary = AnimationLibraryCache.get_library()
	if lib == null or lib.get_animation_list().is_empty():
		return false

	var tree := AnimationTree.new()
	tree.name = "AnimationTree"
	add_child(tree)
	tree.add_animation_library("", lib)
	tree.root_node = tree.get_path_to(skeleton.get_parent())
	tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE

	var blend := AnimationNodeBlendTree.new()

	var idle := AnimationNodeAnimation.new()
	blend.add_node("Idle", idle, Vector2(0, 0))

	var move := AnimationNodeBlendSpace2D.new()
	move.min_space = Vector2(-1.2, -1.2)
	move.max_space = Vector2(1.2, 1.2)
	move.snap = Vector2(0.1, 0.1)
	move.sync = true
	for clip in AnimationSet.LOCOMOTION:
		var point := AnimationNodeAnimation.new()
		point.animation = AnimationLibraryCache._key(clip)
		move.add_blend_point(point, AnimationSet.LOCOMOTION[clip])
	# A ninth point at the centre. The eight real clips form a ring, and
	# Godot's triangulation of a ring can leave the middle uncovered; the
	# centre is blended out by Loco anyway, so which clip sits there does not
	# matter, only that the space is defined everywhere.
	var centre := AnimationNodeAnimation.new()
	centre.animation = AnimationLibraryCache._key("jog forward")
	move.add_blend_point(centre, Vector2.ZERO)
	blend.add_node("Move", move, Vector2(0, 150))

	var scale := AnimationNodeTimeScale.new()
	blend.add_node("MoveScale", scale, Vector2(250, 150))

	var loco := AnimationNodeBlend2.new()
	loco.sync = true
	blend.add_node("Loco", loco, Vector2(450, 60))

	var action := AnimationNodeAnimation.new()
	blend.add_node("Action", action, Vector2(450, 260))

	var shot := AnimationNodeOneShot.new()
	shot.mix_mode = AnimationNodeOneShot.MIX_MODE_BLEND
	blend.add_node("Shot", shot, Vector2(650, 150))

	blend.connect_node("MoveScale", 0, "Move")
	blend.connect_node("Loco", 0, "Idle")
	blend.connect_node("Loco", 1, "MoveScale")
	blend.connect_node("Shot", 0, "Loco")
	blend.connect_node("Shot", 1, "Action")
	blend.connect_node("output", 0, "Shot")

	tree.tree_root = blend
	tree.active = true

	_tree = tree
	_action_node = action
	_apply_idle_clip()
	return true


func _apply_idle_clip() -> void:
	if _tree == null or _tree.tree_root == null:
		return
	var idle := _tree.tree_root.get_node("Idle") as AnimationNodeAnimation
	if idle == null:
		return
	idle.animation = AnimationLibraryCache._key(
		AnimationSet.IDLE_CLIP_KEEPER if _is_keeper else AnimationSet.IDLE_CLIP)


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found: Skeleton3D = _find_skeleton(child)
		if found:
			return found
	return null


## Rotates the upper-arm bone (only) on each side from its bind-pose
## horizontal T-pose direction down to a relaxed hang. Deliberately the
## *only* bone touched: rotating just the shoulder joint's own transform
## carries the elbow/wrist/fingers (its children) rigidly along via normal
## skeleton hierarchy evaluation -- no separate per-bone position/rotation
## bookkeeping needed, and nothing to get out of sync.
##
## A static pose fix, not an animation, and since v0.9.2 only the FALLBACK
## for a rig with no clips available. Bone names are the humanoid profile's,
## because import-time retargeting renames every mapped bone -- 'Arm_L_0267'
## became 'LeftUpperArm'. The old prefix form is still tried second so a rig
## that somehow arrives un-retargeted is not left as a floating cross.
func _fix_tpose_arms(skeleton: Skeleton3D) -> void:
	_fix_upper_arm(skeleton, "LeftUpperArm", "LeftLowerArm", "Arm_L", "Elbow_L",
		Vector3(_TPOSE_UPPER_ARM_TARGET.x, _TPOSE_UPPER_ARM_TARGET.y, _TPOSE_UPPER_ARM_TARGET.z))
	_fix_upper_arm(skeleton, "RightUpperArm", "RightLowerArm", "Arm_R", "Elbow_R",
		Vector3(-_TPOSE_UPPER_ARM_TARGET.x, _TPOSE_UPPER_ARM_TARGET.y, _TPOSE_UPPER_ARM_TARGET.z))


func _fix_upper_arm(skeleton: Skeleton3D, profile_bone: String, profile_child: String,
		legacy_bone: String, legacy_child: String, target_dir_local: Vector3) -> void:
	var bone_idx: int = skeleton.find_bone(profile_bone)
	var child_idx: int = skeleton.find_bone(profile_child)
	if bone_idx < 0 or child_idx < 0:
		bone_idx = _find_bone_exact(skeleton, legacy_bone)
		child_idx = _find_bone_exact(skeleton, legacy_child)
	if bone_idx < 0 or child_idx < 0:
		return

	var self_rest: Transform3D = skeleton.get_bone_global_rest(bone_idx)
	var child_rest: Transform3D = skeleton.get_bone_global_rest(child_idx)
	var current_dir: Vector3 = child_rest.origin - self_rest.origin
	if current_dir.length() < 0.001:
		return

	var delta_rotation := Quaternion(current_dir.normalized(), target_dir_local.normalized())
	var new_basis: Basis = Basis(delta_rotation) * self_rest.basis
	# The shoulder joint's own position never moves, only its orientation --
	# children (elbow/wrist/fingers) automatically follow since they have
	# no override of their own and inherit this bone's new global transform.
	skeleton.set_bone_global_pose_override(bone_idx, Transform3D(new_basis, self_rest.origin), 1.0, true)


## Exact-match bone lookup for the pre-retarget naming convention:
## "<prefix>_<numeric suffix>" (e.g. "Arm_L_0267"), where the suffix varies
## per model and isn't meaningful -- but several *other* real bones share the
## same prefix as a plain string (e.g. "Wrist_L_IK_Handle_0302"), so a plain
## begins_with() would be ambiguous. Requiring the remainder to be purely
## numeric picks the actual bone and rejects those IK/Handle helpers.
func _find_bone_exact(skeleton: Skeleton3D, prefix: String) -> int:
	var want: String = prefix + "_"
	for i in range(skeleton.get_bone_count()):
		var bone_name: String = skeleton.get_bone_name(i)
		if bone_name.begins_with(want):
			var suffix: String = bone_name.substr(want.length())
			if suffix.is_valid_int():
				return i
	return -1


## Rendered height of the model, in the units it will be displayed at. Uses
## each Mesh *resource's* AABB rather than the node's cached visual AABB,
## since the resource's bounds are valid immediately (baked in at import)
## without waiting on a render frame -- important because this runs
## synchronously during spawn.
##
## A SKINNED mesh is not drawn where its node sits. Its vertices go through
## the skin's bind pose and then the bones, so the node transform says almost
## nothing about the size on screen, and the bind pose's scale says everything.
## On this roster that scale is 0.01: the mesh resources measure ~21 units
## tall and render at ~0.21. Measuring by node transform alone therefore
## reported a height a hundred times too large, and the auto-fit divided by
## it -- every character would have spawned about 1.6cm tall. (That is a
## v0.9.2 regression from turning on retarget/rest_fixer/apply_node_transforms,
## which rebaked where those transforms live; the character pipeline suite
## caught it, which is what its bind-pose height check is for.)
func _measure_height(root: Node) -> float:
	var skeleton: Skeleton3D = _find_skeleton(root)
	var bind_scale: float = _skin_bind_scale(skeleton)

	var aabb := AABB()
	var first := true
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D and node.mesh:
			var local_aabb: AABB = node.mesh.get_aabb()
			var xform: Transform3D = node.global_transform
			if (node as MeshInstance3D).skin != null:
				# Skinned: the bind pose carries the scale the vertices are
				# really drawn at, and the skeleton node's own transform
				# carries the rest.
				var skel_basis: Basis = skeleton.global_transform.basis if skeleton else Basis.IDENTITY
				xform = Transform3D(skel_basis.scaled(Vector3.ONE * bind_scale), Vector3.ZERO)
			var world_aabb: AABB = _transform_aabb(xform, local_aabb)
			if first:
				aabb = world_aabb
				first = false
			else:
				aabb = aabb.merge(world_aabb)
		for child in node.get_children():
			stack.append(child)
	return aabb.size.y


## Uniform scale baked into a skeleton's skin bind poses, i.e. how much the
## mesh's own units are shrunk on their way to bone space. 1.0 when there is
## no skin to ask.
func _skin_bind_scale(skeleton: Skeleton3D) -> float:
	if skeleton == null:
		return 1.0
	for c in skeleton.get_children():
		var mi := c as MeshInstance3D
		if mi != null and mi.skin != null and mi.skin.get_bind_count() > 0:
			return mi.skin.get_bind_pose(0).basis.get_scale().y
	return 1.0


func _transform_aabb(xform: Transform3D, aabb: AABB) -> AABB:
	var corners := [
		aabb.position,
		aabb.position + Vector3(aabb.size.x, 0, 0),
		aabb.position + Vector3(0, aabb.size.y, 0),
		aabb.position + Vector3(0, 0, aabb.size.z),
		aabb.position + Vector3(aabb.size.x, aabb.size.y, 0),
		aabb.position + Vector3(aabb.size.x, 0, aabb.size.z),
		aabb.position + Vector3(0, aabb.size.y, aabb.size.z),
		aabb.position + aabb.size,
	]
	var result := AABB()
	var first := true
	for c in corners:
		var wc: Vector3 = xform * c
		if first:
			result = AABB(wc, Vector3.ZERO)
			first = false
		else:
			result = result.expand(wc)
	return result
