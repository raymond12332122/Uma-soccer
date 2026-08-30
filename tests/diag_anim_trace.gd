extends Node3D

## v0.9.2.2: what do outfield players ACTUALLY select during a match?
## (brief section 2)
##
## The v0.9.2.1 metadata tests proved the role table is sound and that the
## controller refuses cross-role intents. Human QA still sees outfield players
## in grounded, sideways, keeper-looking poses. Both can be true: the role gate
## can be perfect while the TRIGGER for a legitimate outfield clip fires far
## too often.
##
## So this records every selection made during a live match -- who, their role,
## what was requested, what it resolved to, its category and the outcome --
## and reports the mix, plus how much of the match each player spends inside a
## grounded action clip rather than on their feet.

const MainScene := preload("res://scenes/Main.tscn")
const SECONDS := 75

## Categories whose clips put the player on or near the floor. These are the
## poses QA is describing; they are legitimate clips, and the question is
## whether they are being played far more often than the game means to.
const GROUNDED := ["TACKLE", "FALL", "GOALKEEPER"]


func _ready() -> void:
	AnimationController.debug_trace = true
	AnimationController.clear_trace()

	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(90):
		await get_tree().physics_frame

	var players: Array = main.home_players + main.away_players
	var outfield: Array = []
	for p in players:
		if not p.is_goalkeeper:
			outfield.append(p)

	var grounded_frames := {}
	var total_frames := 0
	for i in range(SECONDS * 60):
		await get_tree().physics_frame
		total_frames += 1
		for p in outfield:
			var ac: AnimationController = p.animation_controller
			if ac == null or not ac.is_animated():
				continue
			var tree: AnimationTree = ac.get_node_or_null("AnimationTree")
			if tree == null or not tree.get("parameters/Shot/active"):
				continue
			var cat: String = ac._category_of(ac.last_action)
			if cat in GROUNDED:
				grounded_frames[p.name] = grounded_frames.get(p.name, 0) + 1

	AnimationController.debug_trace = false
	_report(outfield, grounded_frames, total_frames)
	get_tree().quit()


func _report(outfield: Array, grounded: Dictionary, frames: int) -> void:
	var trace: Array = AnimationController.trace
	print("TRACE: %d selections recorded over %ds" % [trace.size(), SECONDS])

	# 1. Did any outfield player select a goalkeeper clip? The runtime proof
	#    section 2 asks for, rather than a metadata assertion.
	var gk_by_outfield: Array = []
	var refusals: Array = []
	var by_intent := {}
	var by_category := {}
	for e in trace:
		by_intent[e["resolved"]] = by_intent.get(e["resolved"], 0) + 1
		by_category[e["category"]] = by_category.get(e["category"], 0) + 1
		if str(e["outcome"]).begins_with("REFUSED"):
			refusals.append(e)
		if e["role"] == "OUTFIELD" and e["category"] == "GOALKEEPER" \
			and not str(e["outcome"]).begins_with("REFUSED"):
			gk_by_outfield.append(e)

	print("TRACE: outfield players that PLAYED a goalkeeper clip: %d" % gk_by_outfield.size())
	for e in gk_by_outfield.slice(0, 8):
		print("TRACE:   !! %s (%s) asked '%s' -> '%s' [%s] %s" % [
			e["who"], e["role"], e["requested"], e["resolved"], e["category"], e["outcome"]])
	print("TRACE: refusals (wrong role, correctly blocked): %d" % refusals.size())
	for e in refusals.slice(0, 8):
		print("TRACE:   -- %s (%s) asked '%s' [%s]" % [
			e["who"], e["role"], e["requested"], e["category"]])

	print("TRACE: ---- what was selected, by intent ----")
	var intents: Array = by_intent.keys()
	intents.sort_custom(func(a, b): return by_intent[a] > by_intent[b])
	for k in intents:
		print("TRACE:   %-20s %5d (%4.1f%%)" % [
			k, by_intent[k], 100.0 * by_intent[k] / maxf(trace.size(), 1)])

	print("TRACE: ---- by category ----")
	for k in by_category:
		print("TRACE:   %-14s %5d (%4.1f%%)" % [
			k, by_category[k], 100.0 * by_category[k] / maxf(trace.size(), 1)])

	# 2. How much of the match does an outfield player spend on the floor?
	#    This is the number that matches what the recording looks like.
	var total_grounded := 0
	var worst := 0
	var worst_who := ""
	for k in grounded:
		total_grounded += grounded[k]
		if grounded[k] > worst:
			worst = grounded[k]
			worst_who = k
	var player_frames: int = frames * maxi(outfield.size(), 1)
	print("TRACE: outfield player-time inside a grounded clip: %.1f%% (%d of %d player-frames)" % [
		100.0 * total_grounded / maxf(player_frames, 1), total_grounded, player_frames])
	print("TRACE: worst single player %.1f%% of the match on the floor (%s)" % [
		100.0 * worst / maxf(frames, 1), worst_who])
	print("TRACE: outfield players that spent ANY time grounded: %d of %d" % [
		grounded.size(), outfield.size()])
