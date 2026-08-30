class_name CameraController
extends Node3D

@export var target_path: NodePath
@export var ball_path: NodePath
@export var follow_speed: float = 5.5
@export var ball_bias: float = 0.28
## Closer/lower than the old distant-simulation framing (was Vector3(0, 9, 7))
## -- players read clearly on a phone screen while still keeping enough
## pitch in view for tactical awareness.
@export var base_camera_offset: Vector3 = Vector3(0, 6, 4.6)
@export var max_extra_back: float = 3.0
@export var zoom_distance_threshold: float = 7.0

## ---- Keeping the camera inside the bowl ----
##
## THE VISUAL ARTIFACT human QA kept reporting. The follow below had no bound
## of any kind: it lerps toward lerp(player, ball, 0.28), and the ball can sit
## in the back of a net at x = +-32.2, so the camera went there too. The end
## stands are 3 x 5 x 40 m slabs whose inner faces are at x = +-36.5, which put
## the camera four and a half metres from a forty-metre wall.
##
## Measured with an object-id render pass (tests/diag_object_id.gd): every
## object gets a unique flat colour and the rendered pixels are histogrammed,
## so this is TRUE screen coverage rather than a bounding-box estimate.
##
##   camera |x|      end stand covers
##      32              21.1%      <- a flat slab over a fifth of the frame
##      29               9.2%
##      25               2.6%      <- a sliver at the frame edge
##      20               0.0%
##
## At 21% it does not read as a stand. It reads as corrupted geometry sweeping
## in from the side, because it is flat-shaded, untextured, and nearer than
## anything else on screen.
##
## The camera is contained rather than the stadium being hidden: nothing is
## culled, no material is touched, the stands render exactly as before. The
## camera simply stops before it presses its nose against one.
##
## The two axes are deliberately NOT symmetric, because the camera is not: it
## looks along -Z, so the stand behind it is invisible however close it gets,
## while the one it faces is scenery until it is close enough to become a wall.
const END_STAND_INNER_FACE := 36.5  ## Field.tscn: StandEast/WestEnd at +-38, 3 m deep
const STAND_CLEARANCE := 10.5       ## 11.5 m measured 2.6%, 7.5 m measured 9.2%
const CAMERA_X_LIMIT := END_STAND_INNER_FACE - STAND_CLEARANCE
## How far the camera may push toward the stand it is facing. Beyond this the
## north stand stops being a backdrop across the top of the frame and starts
## being a wall; it measured 8.8% at camera z = -12.4, which still reads as
## stadium.
const CAMERA_Z_FORWARD_LIMIT := -16.0

@onready var camera: Camera3D = $Camera3D

var target: Node3D
var ball: Node3D


func _ready() -> void:
	if target_path != NodePath():
		target = get_node(target_path)
	if ball_path != NodePath():
		ball = get_node(ball_path)
	if camera:
		camera.position = base_camera_offset


## Runtime retargeting -- used by MatchManager on player switch, since the
## human-controlled player (and therefore the camera's follow target) can
## change at any time.
func set_target(node: Node3D) -> void:
	target = node


func set_ball(node: Node3D) -> void:
	ball = node


func _process(delta: float) -> void:
	if target == null:
		return

	var focus_pos: Vector3 = target.global_position
	if ball:
		focus_pos = focus_pos.lerp(ball.global_position, ball_bias)

	global_position.x = lerp(global_position.x, focus_pos.x, follow_speed * delta)
	global_position.z = lerp(global_position.z, focus_pos.z, follow_speed * delta)

	if ball and camera:
		var separation: float = target.global_position.distance_to(ball.global_position)
		var extra: float = clampf(separation - zoom_distance_threshold, 0.0, 10.0)
		var extra_back: float = minf(extra * 0.4, max_extra_back)
		var desired_offset: Vector3 = base_camera_offset + Vector3(0, extra_back * 0.5, extra_back)
		camera.position = camera.position.lerp(desired_offset, follow_speed * delta)

	_contain()


## Clamp the rig so the CAMERA -- not the rig -- stays inside the bowl.
##
## The distinction matters: the camera sits at rig + base_camera_offset, which
## trails up to 7.6 m along +Z, so clamping the rig would leave the camera
## itself unbounded on that axis. This clamps the thing that actually does the
## looking.
##
## Applied after the follow so it is a hard bound rather than something the
## lerp can creep past, and applied every frame so a teleporting focus (a goal
## restart, a player switch across the pitch) cannot slip through it.
func _contain() -> void:
	global_position.x = clampf(global_position.x, -CAMERA_X_LIMIT, CAMERA_X_LIMIT)
	if camera:
		# Only the forward direction needs bounding; see CAMERA_Z_FORWARD_LIMIT.
		var min_rig_z: float = CAMERA_Z_FORWARD_LIMIT - camera.position.z
		global_position.z = maxf(global_position.z, min_rig_z)
