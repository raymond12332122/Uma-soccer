class_name AnimationController
extends Node3D

## Bridges FootballPlayer's gameplay state to whatever visual character is
## currently assigned via PlayerData.visual_id. FootballPlayer only ever
## talks to this narrow interface:
##
##   set_visual(visual_id)   -- (re)builds the displayed character
##   set_state(state)        -- continuous locomotion/possession state
##   play_action(action)     -- one-shot triggered action
##   set_team_color(color)   -- team tint (placeholder capsule only; a
##                              real character keeps its authored textures)
##
## It never needs to know whether the current visual has real animation
## clips. If a model ships clips whose names loosely match a requested
## state/action (see STATE_KEYWORDS/ACTION_KEYWORDS), they're used
## automatically. If not -- exactly the case for the first integrated
## model, which has zero animations -- this falls back to lightweight
## procedural motion (bob/lean/pulse) so the game is never silently
## static. Swapping in a properly-animated model later is a data change
## (CharacterRegistry) plus clip-name matching; no FootballPlayer changes.

@export var target_height: float = 1.6
## Extra correction if a model's own "front" doesn't already face +Z after
## import (this project's forward convention). 0 = no correction needed --
## true for the model shipped in v0.4, verified against its rig data.
@export var facing_correction_degrees: float = 0.0

const STATE_KEYWORDS := {
	"idle": ["idle"],
	"walk": ["walk"],
	"run": ["run", "jog"],
	"sprint": ["sprint", "dash"],
	"dribble": ["dribble"],
	"sitting": ["sit"],
}
const ACTION_KEYWORDS := {
	"pass": ["pass"],
	"shoot": ["shoot", "kick"],
	"celebration": ["celebrat", "cheer", "goal"],
	"tackle": ["tackle", "slide"],
	"look_around": ["look"],
	"excited_reaction": ["excite", "hype"],
	"frustrated_reaction": ["frustrat", "annoy"],
	"victory_pose": ["victory", "pose", "triumph"],
}
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
var _anim_player: AnimationPlayer = null
var _state_clip_map: Dictionary = {}
var _action_clip_map: Dictionary = {}
var _uses_real_model: bool = false

var _current_state: String = "idle"
var _procedural_time: float = 0.0
var _pulse_kind: String = ""
var _pulse_time: float = -1.0

## Diagnostic only (read by tests/tools) -- the height measured before the
## auto-fit scale was applied, in whatever units the source file used.
var last_measured_height: float = 0.0

## Diagnostic only (read by tests) -- true once _fix_tpose_arms() has run
## for the current real-model visual (see _setup_real_model).
var t_pose_fixed: bool = false

## Relaxed-hang target direction for the upper arm bone, in skeleton-local
## space (Y-up, confirmed empirically for every currently-integrated
## model). X is mirrored per side; a small outward/forward bias keeps the
## arm from clipping straight through the torso.
const _TPOSE_UPPER_ARM_TARGET := Vector3(0.18, -1.0, 0.08)


func set_visual(visual_id: String) -> void:
	if _visual_root:
		_visual_root.queue_free()
	_visual_root = null
	_anim_player = null
	_state_clip_map.clear()
	_action_clip_map.clear()
	_pulse_kind = ""
	_pulse_time = -1.0
	t_pose_fixed = false

	var scene: PackedScene = CharacterRegistry.get_scene(visual_id)
	if scene:
		_uses_real_model = true
		_setup_real_model(scene)
	else:
		_uses_real_model = false
		_setup_placeholder()


func supports_team_tint() -> bool:
	return not _uses_real_model


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


## Continuous locomotion/possession state, called every physics frame by
## FootballPlayer. Cheap to call redundantly -- no-ops if unchanged.
func set_state(state: String) -> void:
	if state == _current_state:
		return
	_current_state = state
	if _anim_player and _state_clip_map.has(state):
		_anim_player.play(_state_clip_map[state])


## One-shot triggered action (pass/shoot/celebration/tackle).
func play_action(action: String) -> void:
	if _anim_player and _action_clip_map.has(action):
		_anim_player.play(_action_clip_map[action])
		return
	_pulse_kind = action
	_pulse_time = 0.0


func _process(delta: float) -> void:
	if _visual_root == null:
		return
	_procedural_time += delta

	if _pulse_time >= 0.0:
		_pulse_time += delta
		var duration: float = PULSE_DURATIONS.get(_pulse_kind, 0.4)
		if _pulse_time > duration:
			_pulse_time = -1.0
			_pulse_kind = ""
		else:
			_apply_action_pulse(_pulse_kind, _pulse_time / duration)
			return

	# Real clips (once a model ships them) drive the visual on their own;
	# procedural motion is purely the fallback for a state with no clip.
	if _anim_player and _state_clip_map.has(_current_state):
		_visual_root.position = Vector3.ZERO
		_visual_root.rotation = Vector3.ZERO
		return

	_apply_state_procedural(_current_state)


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

	if facing_correction_degrees != 0.0:
		instance.rotate_y(deg_to_rad(facing_correction_degrees))

	_anim_player = _find_animation_player(instance)
	if _anim_player == null or _anim_player.get_animation_list().is_empty():
		_anim_player = null
	else:
		_build_clip_maps()

	# Every currently-integrated model ships in a bind pose (T-pose: arms
	# straight out horizontally) with zero animation clips, so without this
	# every character would stand/run around looking like a floating cross.
	# Only relevant on the no-real-clips path -- a model with real clips
	# handles its own posing once played.
	if _anim_player == null:
		var skeleton: Skeleton3D = _find_skeleton(instance)
		if skeleton:
			_fix_tpose_arms(skeleton)
			t_pose_fixed = true


func _build_clip_maps() -> void:
	for clip_name in _anim_player.get_animation_list():
		var lower: String = clip_name.to_lower()
		for state in STATE_KEYWORDS:
			if _state_clip_map.has(state):
				continue
			for keyword in STATE_KEYWORDS[state]:
				if lower.contains(keyword):
					_state_clip_map[state] = clip_name
					break
		for action in ACTION_KEYWORDS:
			if _action_clip_map.has(action):
				continue
			for keyword in ACTION_KEYWORDS[action]:
				if lower.contains(keyword):
					_action_clip_map[action] = clip_name
					break


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found: AnimationPlayer = _find_animation_player(child)
		if found:
			return found
	return null


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
## bookkeeping needed, and nothing to get out of sync. Every
## currently-integrated model shares one rig convention (verified: same
## bone names, same near-identical T-pose rest direction on all 11), so
## one fixed target direction generalizes across the whole roster without
## per-character special-casing.
##
## A static pose fix, not an animation -- legs are already in a natural
## standing position at rest (not spread) and are left untouched. Full
## walk/run gait animation is intentionally out of scope here; see the
## README's Roadmap.
func _fix_tpose_arms(skeleton: Skeleton3D) -> void:
	_fix_upper_arm(skeleton, "Arm_L", Vector3(_TPOSE_UPPER_ARM_TARGET.x, _TPOSE_UPPER_ARM_TARGET.y, _TPOSE_UPPER_ARM_TARGET.z))
	_fix_upper_arm(skeleton, "Arm_R", Vector3(-_TPOSE_UPPER_ARM_TARGET.x, _TPOSE_UPPER_ARM_TARGET.y, _TPOSE_UPPER_ARM_TARGET.z))


func _fix_upper_arm(skeleton: Skeleton3D, bone_prefix: String, target_dir_local: Vector3) -> void:
	var bone_idx: int = _find_bone_exact(skeleton, bone_prefix)
	var child_idx: int = _find_bone_exact(skeleton, bone_prefix.replace("Arm_", "Elbow_"))
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


## Exact-match bone lookup: skeleton bone names are "<prefix>_<numeric
## suffix>" (e.g. "Arm_L_0267"), where the suffix varies per model/import
## and isn't meaningful -- but several *other* real bones share the same
## prefix as a plain string (e.g. "Wrist_L_IK_Handle_0302" also starts
## with "Wrist_L_"), so a plain begins_with() would be ambiguous. Requiring
## the remainder after "<prefix>_" to be purely numeric picks the actual
## bone and rejects those IK/Handle helper bones.
func _find_bone_exact(skeleton: Skeleton3D, prefix: String) -> int:
	var want: String = prefix + "_"
	for i in range(skeleton.get_bone_count()):
		var bone_name: String = skeleton.get_bone_name(i)
		if bone_name.begins_with(want):
			var suffix: String = bone_name.substr(want.length())
			if suffix.is_valid_int():
				return i
	return -1


## Bind-pose bounding-box height of every mesh under `root`, in the
## model's own imported units. Uses each Mesh *resource's* AABB rather
## than the node's cached visual AABB, since the resource's bounds are
## valid immediately (baked in at import) without waiting on a render
## frame -- important because this runs synchronously during spawn.
func _measure_height(root: Node) -> float:
	var aabb := AABB()
	var first := true
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D and node.mesh:
			var local_aabb: AABB = node.mesh.get_aabb()
			var world_aabb: AABB = _transform_aabb(node.global_transform, local_aabb)
			if first:
				aabb = world_aabb
				first = false
			else:
				aabb = aabb.merge(world_aabb)
		for child in node.get_children():
			stack.append(child)
	return aabb.size.y


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
