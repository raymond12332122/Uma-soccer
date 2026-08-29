class_name BallController
extends RigidBody3D

@export var reset_height: float = -10.0
@export var max_speed: float = 17.0

## v0.9.1.1: how far the ball must get from a player before that player's
## collision exception is dropped. The two bodies' radii plus a margin, so
## the exception ends the moment the ball is genuinely clear rather than on
## a timer that has to guess at launch speed.
const CLEARANCE_DISTANCE := 0.40 + 0.16 + 0.25

## Hard ceiling on an exception, in seconds, in case a ball never gets clear
## (trapped against a wall, a player standing on it). Without this a stuck
## ball would stay permanently intangible to whoever last held it.
const CLEARANCE_MAX_TIME := 1.5

var spawn_position: Vector3

## player -> seconds remaining. A player in here does not collide with the
## ball. See pass_through_for().
var _exceptions: Dictionary = {}


func _ready() -> void:
	spawn_position = global_position
	add_to_group("ball")


## Let `player` pass through the ball until the ball is clear of them.
##
## v0.9.1.1. The ball collides with players again (see Ball.tscn's mask), so
## a keeper has something to save with and a defender something to block
## with. Two cases still need the ball to ignore a specific player:
##
##   THE CARRIER  -- close control steers the ball to a point ahead of the
##                   player with a spring force. If the ball ALSO physically
##                   bounces off that player's capsule, the two fight and the
##                   dribble turns to jitter.
##   THE KICKER   -- the ball leaves from the player's feet, i.e. from inside
##                   their own capsule. Without an exception a shot rebounds
##                   off the shooter immediately; that is what broke v0_7's
##                   scoring assertions when the ball's mask was first
##                   restored, and it is what the blanket "ball ignores
##                   everybody" fix in v0.9.1 was papering over.
##
## Both are per-player and temporary. Everyone else blocks the ball normally.
func pass_through_for(player: PhysicsBody3D) -> void:
	if player == null or not is_instance_valid(player):
		return
	if not _exceptions.has(player):
		add_collision_exception_with(player)
	_exceptions[player] = CLEARANCE_MAX_TIME


func _physics_process(delta: float) -> void:
	if global_position.y < reset_height:
		reset_ball()
		return

	if linear_velocity.length() > max_speed:
		linear_velocity = linear_velocity.normalized() * max_speed

	_expire_exceptions(delta)


## An exception ends when the ball is clear of that player, or when its time
## runs out -- whichever comes first.
func _expire_exceptions(delta: float) -> void:
	if _exceptions.is_empty():
		return
	for player in _exceptions.keys():
		if not is_instance_valid(player):
			_exceptions.erase(player)
			continue
		var t: float = _exceptions[player] - delta
		var gap: float = Vector2(
			global_position.x - player.global_position.x,
			global_position.z - player.global_position.z).length()
		if gap > CLEARANCE_DISTANCE or t <= 0.0:
			remove_collision_exception_with(player)
			_exceptions.erase(player)
		else:
			_exceptions[player] = t


func reset_ball() -> void:
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	global_position = spawn_position
	for player in _exceptions.keys():
		if is_instance_valid(player):
			remove_collision_exception_with(player)
	_exceptions.clear()
