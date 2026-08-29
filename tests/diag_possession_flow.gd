extends Node3D

## v0.9.1.1: how long does anybody actually KEEP the ball?
##
## v0_8_3's sample-size guards started failing ("sampled enough carrier
## frames (18)"), which is not a claim about decisions -- it is a claim that
## possession has become too fragmented for the suite to observe. Two v0.9.1.1
## changes could plausibly do that:
##
##   - the ball collides with players again, so a dribbled ball can be
##     knocked loose by anyone it runs into
##   - possession cannot be ACQUIRED from a ball moving faster than
##     CONTROLLED_BALL_SPEED, so a loose ball has to settle before anyone
##     picks it up
##
## Both are correct in themselves. The question is whether together they have
## turned the match into pinball, which is a feel regression even though no
## assertion names it.

const MainScene := preload("res://scenes/Main.tscn")

const SECONDS := 90


func _ready() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(120):
		await get_tree().physics_frame

	var pm: PossessionManager = main.possession_manager
	var spells: Array = []
	var current := 0
	var carried_frames := 0
	var loose_frames := 0
	var prev: FootballPlayer = null

	for i in range(SECONDS * 60):
		await get_tree().physics_frame
		var c: FootballPlayer = pm.current_carrier
		if c != null and is_instance_valid(c):
			carried_frames += 1
			if c == prev:
				current += 1
			else:
				if current > 0:
					spells.append(current)
				current = 1
		else:
			loose_frames += 1
			if current > 0:
				spells.append(current)
			current = 0
		prev = c
	if current > 0:
		spells.append(current)

	var total: int = SECONDS * 60
	print("DIAG-FLOW: %.0f%% of frames had a carrier, %.0f%% loose" % [
		100.0 * carried_frames / total, 100.0 * loose_frames / total])
	if spells.is_empty():
		print("DIAG-FLOW: no possession spells at all")
		get_tree().quit()
		return
	spells.sort()
	var sum := 0
	for v in spells:
		sum += v
	var longest: int = spells[spells.size() - 1]
	print("DIAG-FLOW: %d possession spells over %ds -- mean %.2fs, median %.2fs, longest %.2fs" % [
		spells.size(), SECONDS, (float(sum) / spells.size()) / 60.0,
		float(spells[spells.size() / 2]) / 60.0, float(longest) / 60.0])
	var brief := 0
	for v in spells:
		if v < 30:
			brief += 1
	print("DIAG-FLOW: spells under half a second: %d of %d (%.0f%%)" % [
		brief, spells.size(), 100.0 * brief / spells.size()])
	get_tree().quit()
