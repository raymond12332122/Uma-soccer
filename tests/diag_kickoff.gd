extends Node3D

## v0.9.1.1: how long after kickoff before anybody actually has the ball?
##
## v0_8_3 samples 300 frames starting 2s after load and needs >30 of them to
## have a carrier. It measures 18, identically on every run. Over a full 90s
## match the same build has a carrier 44% of the time, so possession is not
## scarce -- it is scarce AT KICKOFF, which is where that window lands.
##
## Plausible cause: v0.9.1.1 refuses possession of a ball moving faster than
## CONTROLLED_BALL_SPEED relative to the player, so the opening scramble for a
## loose centre-circle ball takes longer to resolve.

const MainScene := preload("res://scenes/Main.tscn")


func _ready() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	await get_tree().physics_frame
	for i in range(120):
		await get_tree().physics_frame

	var pm: PossessionManager = main.possession_manager
	var first := -1
	var carrier_frames := 0
	for i in range(300):
		await get_tree().physics_frame
		if pm.current_carrier != null and is_instance_valid(pm.current_carrier):
			carrier_frames += 1
			if first < 0:
				first = i
	print("DIAG-KO: first carrier at frame %s, %d of 300 frames had a carrier (%.0f%%)" % [
		("%d (%.2fs)" % [first, first / 60.0]) if first >= 0 else "NEVER",
		carrier_frames, 100.0 * carrier_frames / 300.0])
	get_tree().quit()
