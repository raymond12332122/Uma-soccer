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


func set_visual(visual_id: String) -> void:
	if _visual_root:
		_visual_root.queue_free()
	_visual_root = null
	_anim_player = null
	_state_clip_map.clear()
	_action_clip_map.clear()
	_pulse_kind = ""
	_pulse_time = -1.0

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
