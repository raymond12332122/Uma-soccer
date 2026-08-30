extends Node3D

## v0.9.2.1: is the keeper still reacting, now that it has an animation set?
## (brief section 4)
##
## Two questions, and the second is the one this milestone created:
##
##   1. Does the keeper recognise and react to each of the seven situations
##      the brief names? Measured as reaction delay and closest approach, not
##      as "did it save", because the requirement is a believable attempt and
##      not an unbeatable goalkeeper.
##
##   2. Is any of that being DELAYED OR SUPPRESSED by an animation state?
##      v0.9.2.1 gives the keeper clips on six intent transitions, and a clip
##      that locked the body would look exactly like a keeper who had stopped
##      trying. So every scenario also records whether the keeper moved while
##      an action clip was playing.
##
## Run: godot --headless --path . tests/DiagKeeperV0921.tscn

const FieldScene := preload("res://scenes/Field.tscn")
const BallScene := preload("res://scenes/Ball.tscn")
const PlayerScene := preload("res://scenes/FootballPlayer.tscn")

const OBSERVE_FRAMES := 110


func _ready() -> void:
	print("KEEPER: scenario | intent | reaction | travelled | closest | moved_while_animating")
	await _scenario("close-range shot", Vector3(6.0, 0.3, 0.0), Vector3(-16.0, 0, 0.0))
	await _scenario("medium-range shot", Vector3(18.0, 0.3, 1.0), Vector3(-14.0, 0, -1.0))
	await _scenario("shot across the keeper", Vector3(12.0, 0.3, -6.0), Vector3(-13.0, 0, 9.0))
	await _scenario("fast uncontrollable ball", Vector3(10.0, 0.3, 0.0), Vector3(-26.0, 0, 0.0))
	await _scenario("slow controllable ball", Vector3(7.0, 0.3, 0.5), Vector3(-3.0, 0, 0.0))
	await _scenario("loose ball near keeper", Vector3(5.0, 0.16, 1.0), Vector3.ZERO)
	await _scenario("attacker running at keeper", Vector3(9.0, 0.16, 0.0), Vector3(-2.0, 0, 0.0), true)
	get_tree().quit()


func _scenario(label: String, ball_offset: Vector3, ball_velocity: Vector3,
		with_attacker: bool = false) -> void:
	var field = FieldScene.instantiate()
	add_child(field)
	var ball: RigidBody3D = BallScene.instantiate()
	add_child(ball)
	await get_tree().physics_frame

	var goal := Vector3(FormationManager.GOAL_LINE_X, 0.0, 0.0)
	var keeper: FootballPlayer = PlayerScene.instantiate()
	add_child(keeper)
	keeper.global_position = goal + Vector3(0, 1, 0)
	keeper.team_id = 0
	keeper.formation_role = "GK"
	keeper.is_goalkeeper = true
	keeper.formation_slot = Vector2(0.0, 0.5)

	var attacker: FootballPlayer = null
	if with_attacker:
		attacker = PlayerScene.instantiate()
		add_child(attacker)
		attacker.global_position = goal + Vector3(12.0, 1, 0)
		attacker.team_id = 1
		attacker.formation_role = "ST"

	await get_tree().physics_frame
	# A visual has to be assigned by hand here. Players spawned without
	# PlayerData never call set_visual, so they have no AnimationTree at all --
	# and then "did a clip stop the keeper moving?" reports "no clip played"
	# for every scenario, which answers nothing. The keeper flag matters too:
	# it is what gives this controller the goalkeeper half of the clip
	# database.
	if keeper.animation_controller:
		keeper.animation_controller.set_visual("tokai_teio")
		keeper.animation_controller.set_keeper(true)
	if attacker != null and attacker.animation_controller:
		attacker.animation_controller.set_visual("gold_ship")

	var opponents: Array = [attacker] if attacker != null else []
	keeper.set_match_context([keeper], opponents)
	if attacker != null:
		attacker.set_match_context([attacker], [keeper])
	for i in range(20):
		await get_tree().physics_frame

	# The ball is placed relative to the goal the keeper is defending, and
	# struck toward it, so every scenario is stated in the keeper's own frame.
	ball.global_position = goal + Vector3(-signf(goal.x) * ball_offset.x, ball_offset.y, ball_offset.z)
	ball.linear_velocity = Vector3(signf(goal.x) * absf(ball_velocity.x), 0.0, ball_velocity.z)
	if ball_velocity.length() < 0.01:
		ball.linear_velocity = Vector3.ZERO

	var start: Vector3 = keeper.global_position
	var reaction := -1.0
	var closest := INF
	var first_intent := -1
	var moved_while_animating := 0.0
	var animating_frames := 0

	for i in range(OBSERVE_FRAMES):
		# The keeper's AI is normally driven by TeamController every frame.
		# There is no TeamController in an isolated scene, so without this the
		# keeper simply stands there and every scenario reports "no reaction"
		# -- a harness failure that looks exactly like the bug being hunted.
		AIController.update_goalkeeper(keeper, ball, goal)
		if attacker != null:
			attacker.move_input = Vector2(signf(goal.x), 0.0)
		var before: Vector3 = keeper.global_position
		await get_tree().physics_frame
		var moved: float = before.distance_to(keeper.global_position)
		if reaction < 0.0 and moved > 0.004:
			reaction = i / 60.0
		closest = minf(closest, keeper.global_position.distance_to(ball.global_position))
		if first_intent < 0 and keeper.gk_intent != AIController.GKIntent.POSITION:
			first_intent = keeper.gk_intent
		# The section-4 question: is a clip stopping the keeper moving?
		var tree: AnimationTree = _tree_of(keeper)
		if tree != null and tree.get("parameters/Shot/active"):
			animating_frames += 1
			moved_while_animating += moved

	var intent_name: String = AIController.GKIntent.keys()[first_intent] if first_intent >= 0 else "POSITION"
	print("KEEPER: %-26s | %-18s | %5s | %6.2fm | %6.2fm | %s" % [
		label, intent_name,
		"%.2fs" % reaction if reaction >= 0.0 else "none",
		start.distance_to(keeper.global_position),
		closest,
		"%.2fm over %d frames" % [moved_while_animating, animating_frames]
			if animating_frames > 0 else "no clip played"])

	for n in [field, ball, keeper, attacker]:
		if n != null and is_instance_valid(n):
			if n.get_parent() != null:
				n.get_parent().remove_child(n)
			n.queue_free()
	await get_tree().physics_frame


func _tree_of(p: FootballPlayer) -> AnimationTree:
	if p.animation_controller == null:
		return null
	return p.animation_controller.get_node_or_null("AnimationTree")
