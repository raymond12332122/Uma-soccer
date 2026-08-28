extends Node3D

## v0.9.0 diagnostic: the touch cycle, in isolation.
##
## Measuring this in the live Main scene does not work -- the carrier is
## surrounded by ten opponents and loses the ball within a second, so the
## numbers describe a scramble rather than a dribble. This puts ONE player
## and the ball on the real pitch with nobody else, and drives them through
## the manoeuvres the milestone asks for:
##
##   run straight / slow down / stop / sharp turn / accelerate away
##
## What a genuine close-control cycle should look like:
##   - touches spaced like footfalls, roughly 1.5-2.5 a second at a run
##   - separation OSCILLATING: ball pushed ahead, then caught up to
##   - ball faster than the player just after a touch, slower just before
##     the next one
## A model that is really pushing the ball shows the opposite: very frequent
## touches, near-constant separation, and a ball speed pinned to the
## player's own.

const FieldScene := preload("res://scenes/Field.tscn")
const PlayerScene := preload("res://scenes/FootballPlayer.tscn")
const BallScene := preload("res://scenes/Ball.tscn")

var _player: FootballPlayer
var _ball: RigidBody3D
var _along: Array = []
var _lateral: Array = []


func _ready() -> void:
	add_child(FieldScene.instantiate())
	_ball = BallScene.instantiate()
	add_child(_ball)
	_player = PlayerScene.instantiate()
	add_child(_player)
	_player.apply_player_data(TestRoster.home_team()[9])
	_player.set_match_context([], [])
	_player.global_position = Vector3(-10, 1, 0)
	await get_tree().physics_frame
	_ball.global_position = _player.global_position + Vector3(0.5, 0.2, 0)
	_ball.linear_velocity = Vector3.ZERO
	for i in range(40):
		await get_tree().physics_frame

	print("DIAG-SOLO: leash walk %.2fm / sprint %.2fm, control radius ~%.2fm" % [
		_player.dribble_distance, _player.dribble_distance_sprint,
		_player.dribble_distance_sprint * FootballPlayer.CONTROL_RADIUS_LEASH_MARGIN])

	await _phase("jog straight", Vector3(1, 0, 0), false, 180)
	await _phase("sprint straight", Vector3(1, 0, 0), true, 180)
	await _phase("sharp turn (90 deg left)", Vector3(0, 0, -1), false, 120)
	await _phase("slow to a stop", Vector3.ZERO, false, 90)
	get_tree().quit()


func _phase(label: String, dir: Vector3, sprint: bool, frames: int) -> void:
	var touches := 0
	var touch_at: Array = []
	_along = []
	_lateral = []
	var seps: Array = []
	var rel: Array = []
	var held := 0
	var lost := 0

	for i in range(frames):
		_player.move_input = Vector2(dir.x, dir.z)
		_player.sprint_requested = sprint
		await get_tree().physics_frame
		if not _player.has_possession:
			lost += 1
			continue
		held += 1
		var off := Vector3(
			_ball.global_position.x - _player.global_position.x, 0.0,
			_ball.global_position.z - _player.global_position.z)
		seps.append(Vector2(off.x, off.z).length())
		# Split the offset into ALONG the dribble line and OFF it. The along
		# axis is driven by discrete touches; the lateral axis is driven by a
		# continuous spring-damper (SHEPHERD_ACCEL), and a lateral figure
		# pinned near zero is what "the ball is attached to the player"
		# actually looks like in numbers.
		if dir.length() > 0.01:
			var d: Vector3 = dir.normalized()
			_along.append(off.dot(d))
			_lateral.append((off - d * off.dot(d)).length())
		rel.append(Vector2(_ball.linear_velocity.x, _ball.linear_velocity.z).length()
			- Vector2(_player.velocity.x, _player.velocity.z).length())
		if _player.touched_ball_this_frame:
			touches += 1
			touch_at.append(i)

	print("DIAG-SOLO: --- %s ---" % label)
	if held == 0:
		print("DIAG-SOLO:   never held the ball (%d frames without possession)" % lost)
		return
	var secs: float = held / 60.0
	print("DIAG-SOLO:   possession %d/%d frames, %d touches = %.1f/s" % [
		held, frames, touches, touches / maxf(secs, 0.01)])
	print("DIAG-SOLO:   separation  %s" % _stats(seps))
	print("DIAG-SOLO:   along the dribble line  %s" % _stats(_along))
	print("DIAG-SOLO:   LATERAL off the line    %s" % _stats(_lateral))
	print("DIAG-SOLO:   ball-minus-player speed  %s" % _stats(rel))
	if touch_at.size() > 1:
		var gaps: Array = []
		for i in range(1, touch_at.size()):
			gaps.append(float(touch_at[i] - touch_at[i - 1]))
		print("DIAG-SOLO:   frames between touches  %s" % _stats(gaps))


func _stats(vals: Array) -> String:
	if vals.is_empty():
		return "(none)"
	var lo := INF
	var hi := -INF
	var sum := 0.0
	for v in vals:
		lo = minf(lo, v)
		hi = maxf(hi, v)
		sum += v
	return "min %+.2f  mean %+.2f  max %+.2f  (swing %.2f)" % [lo, sum / vals.size(), hi, hi - lo]
