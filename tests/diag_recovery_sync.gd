extends Node3D

## Blocker 3: does gameplay hand control back before the player has got up?
##
## Measures, frame by frame, a single knockdown:
##
##   the frame the DOWN timers expire            (movement returns today)
##   the frame the recovery clip actually ends   (is_action_playing goes false)
##   whether the player moves in between
##
## The gap between those two frames is the defect. A player who is free to
## sprint while the get-up clip is still playing from frame zero is the
## "fall/collision/recovery desynchronisation" QA is describing.
##
## Runs headless. Animation is driven on idle frames, which run without a
## renderer, so this is a second of simulation rather than a rendered capture.

const MainScene := preload("res://scenes/Main.tscn")

## How the player is driven while down. A human holding the stick is the worst
## case: the instant control returns, they move.
enum Drive { NONE, HUMAN, AI }


func _ready() -> void:
	print("RECOVERY: ==== knockdown timeline ====")
	await _measure("human input", Drive.HUMAN, 1.0)
	await _measure("no input", Drive.NONE, 1.0)
	await _measure("half-speed animation", Drive.HUMAN, 0.5)
	get_tree().quit()


func _measure(label: String, drive: int, anim_scale: float) -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(40):
		await get_tree().physics_frame

	main.home_team.set_physics_process(false)
	main.away_team.set_physics_process(false)
	if main.player_controller != null:
		main.player_controller.set_physics_process(false)

	var victim: FootballPlayer = main.home_players[5]
	# Everyone else parked well away so nothing interferes.
	var i2 := 0
	for p in (main.home_players + main.away_players):
		if p == victim:
			continue
		p.movement_locked = true
		p.move_input = Vector2.ZERO
		p.global_position = Vector3(-30.0 + float(i2) * 3.0, p.global_position.y, -21.0)
		i2 += 1
	victim.global_position = Vector3(0, victim.global_position.y, 0)
	main.ball.global_position = Vector3(6, 0.16, 6)
	main.ball.linear_velocity = Vector3.ZERO
	for i in range(20):
		await get_tree().physics_frame

	var ac: AnimationController = victim.animation_controller
	if ac != null and anim_scale != 1.0:
		var tree: AnimationTree = ac.get_node_or_null("AnimationTree")
		if tree != null:
			# Half-speed playback of the ACTION branch specifically. AnimationTree
			# has no speed_scale in Godot 4 and MoveScale only rates locomotion,
			# so this rides the ActionScale node added for exactly this purpose.
			tree.set("parameters/ActionScale/scale", anim_scale)

	var start_pos: Vector3 = victim.global_position
	victim.begin_stumble(SlideTackle.STUMBLE_TIME)

	var unlock_frame := -1
	var anim_end_frame := -1
	var moved_while_recovering := 0.0
	var last_pos: Vector3 = victim.global_position
	var was_playing := false

	for f in range(600):
		if drive == Drive.HUMAN:
			victim.move_input = Vector2(1, 0)
			victim.sprint_requested = true
		await get_tree().physics_frame

		var down: bool = victim.stumble_time > 0.0 or victim.slide_recovery > 0.0
		var locked: bool = victim.is_recovering() if victim.has_method("is_recovering") else down
		var playing: bool = ac != null and ac.is_action_playing()
		if playing:
			was_playing = true

		if unlock_frame < 0 and not locked:
			unlock_frame = f
		if unlock_frame >= 0 and anim_end_frame < 0 and was_playing and not playing:
			anim_end_frame = f
		# Planar movement accrued while the recovery clip is still running.
		if playing and unlock_frame >= 0:
			moved_while_recovering += Vector2(
				victim.global_position.x - last_pos.x,
				victim.global_position.z - last_pos.z).length()
		last_pos = victim.global_position
		if unlock_frame >= 0 and anim_end_frame >= 0 and f > anim_end_frame + 30:
			break

	print("RECOVERY: [%s]" % label)
	print("RECOVERY:   control returned at frame      %d" % unlock_frame)
	print("RECOVERY:   recovery clip finished at      %s" % [
		"never observed" if anim_end_frame < 0 else str(anim_end_frame)])
	print("RECOVERY:   desync (free but still rising) %s frames" % [
		"n/a" if anim_end_frame < 0 or unlock_frame < 0 else str(anim_end_frame - unlock_frame)])
	print("RECOVERY:   planar movement while rising   %.3f m" % moved_while_recovering)
	print("RECOVERY:   total displacement             %.3f m" % [
		Vector2(victim.global_position.x - start_pos.x,
			victim.global_position.z - start_pos.z).length()])

	main.get_parent().remove_child(main)
	main.queue_free()
	for i in range(3):
		await get_tree().physics_frame
