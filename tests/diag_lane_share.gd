extends Node3D

## v0.8.8 diagnostic: is the "clear passing lane" SHARE falling because
## fewer lanes are clear, or because more teammates are in range?
##
## v0_8_7_football_feel_test asserts that >50% of in-range teammates have a
## clear lane to the carrier. That is a RATIO, and a ratio can fall while
## the thing it is measuring improves: if a change puts more teammates
## inside passing range, the denominator grows and the share drops even
## though the carrier has strictly more options to choose from.
##
## v0.8.8 re-fitted the ball roll model, which changes how far every pass
## travels and therefore where players end up relative to one another, so
## this is exactly the confound to rule in or out. It reports the numerator
## and denominator separately, per carrier frame, so the two builds can be
## compared on absolute options as well as on the ratio.
##
## Deliberately written against APIs that exist in BOTH v0.8.7 and v0.8.8 so
## the same file can be dropped into either tree.

const MainScene := preload("res://scenes/Main.tscn")


func _ready() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	await get_tree().physics_frame
	for i in range(120):
		await get_tree().physics_frame

	var carrier_frames := 0
	var in_range_sum := 0.0
	var clear_sum := 0.0

	for i in range(int(35.0 * 60.0)):
		await get_tree().physics_frame
		var carrier: FootballPlayer = main.possession_manager.current_carrier
		if carrier == null or not is_instance_valid(carrier):
			continue
		carrier_frames += 1
		for mate in carrier.teammates:
			if mate == carrier or mate == null or not is_instance_valid(mate):
				continue
			if mate.is_goalkeeper:
				continue
			var to_mate: Vector3 = mate.global_position - carrier.global_position
			to_mate.y = 0.0
			var d: float = to_mate.length()
			if d < PassEvaluator.MIN_PASS_DISTANCE or d > PassEvaluator.MAX_PASS_DISTANCE:
				continue
			in_range_sum += 1.0
			if not PassEvaluator._lane_blocked(carrier.global_position, to_mate / d, d, carrier.opponents):
				clear_sum += 1.0

	var frames: float = maxf(carrier_frames, 1)
	print("DIAG-LANE: %d carrier frames" % carrier_frames)
	print("DIAG-LANE:   teammates IN RANGE per frame : %.2f" % (in_range_sum / frames))
	print("DIAG-LANE:   teammates with a CLEAR lane  : %.2f   <-- absolute options" % (clear_sum / frames))
	print("DIAG-LANE:   share with a clear lane      : %.0f%%  <-- what the test asserts" % (
		100.0 * clear_sum / maxf(in_range_sum, 1.0)))
	get_tree().quit()
