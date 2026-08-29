extends Node3D

## v0.9.1 diagnostic: WHICH duty changes are the churn?
##
## Measured (V0_8_5PossessionPhaseTest, paired runs): 0.360 duty changes per
## player per second of settled possession with the RECEIVE duty enabled,
## 0.242 without it, against a v0.9.0 baseline of 0.178 and a 0.30 ceiling.
## So RECEIVE costs ~0.12 even now that it is applied as a non-destructive
## override that reallocates nobody else.
##
## The obvious arithmetic does not obviously reach 0.12: one pass should be
## two duty changes for one player (into RECEIVE, then back out), and at the
## observed pass rate that is worth about half of what is measured. This
## counts the transitions directly instead of reasoning about them -- every
## duty change during settled play, bucketed by which duty it left and which
## it arrived at, so "RECEIVE flickering on and off within a single pass"
## and "RECEIVE displacing a duty once per pass" look completely different
## in the output.

const MainScene := preload("res://scenes/Main.tscn")

const SECONDS := 60

const DUTY_NAMES := ["CONTEST", "PRESS_SUPPORT", "SUPPORT_SHORT", "SUPPORT_WIDE",
	"RUN_BEHIND", "MARK", "COVER_SPACE", "FOLLOW_UP", "PUSH_UP", "RECEIVE"]


func _ready() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(120):
		await get_tree().physics_frame

	var players: Array = main.home_players + main.away_players
	var pm: PossessionManager = main.possession_manager

	var prev_duty := {}
	var transitions := {}
	var total := 0
	var stable_frames := 0
	# How long a spell of RECEIVE lasts, in frames. A healthy value is
	# "about as long as a pass is in the air"; a pile of 1-2 frame spells is
	# flicker.
	var receive_spells: Array = []
	var receive_since := {}

	for i in range(SECONDS * 60):
		await get_tree().physics_frame
		var stable: bool = pm.time_since_last_team_change > 1.0
		if stable:
			stable_frames += 1
		for p in players:
			var id: int = p.get_instance_id()
			var now: int = p.ai_duty
			var was = prev_duty.get(id, null)
			if was != null and was != now:
				if stable:
					var key: String = "%s -> %s" % [_name(was), _name(now)]
					transitions[key] = transitions.get(key, 0) + 1
					total += 1
				if was == TeamPlan.Duty.RECEIVE and receive_since.has(id):
					receive_spells.append(i - receive_since[id])
					receive_since.erase(id)
				if now == TeamPlan.Duty.RECEIVE:
					receive_since[id] = i
			prev_duty[id] = now

	print("DIAG-CHURN: %d duty changes over %d settled frames (%.3f per player per second)" % [
		total, stable_frames, total / maxf(stable_frames / 60.0, 0.01) / players.size()])

	var keys: Array = transitions.keys()
	keys.sort_custom(func(a, b): return transitions[a] > transitions[b])
	print("DIAG-CHURN: most common transitions --")
	for k in keys.slice(0, 12):
		print("DIAG-CHURN:   %-34s %4d  (%.0f%%)" % [k, transitions[k],
			100.0 * transitions[k] / maxf(total, 1)])

	var involving_receive := 0
	for k in keys:
		if String(k).contains("RECEIVE"):
			involving_receive += transitions[k]
	print("DIAG-CHURN: transitions involving RECEIVE: %d of %d (%.0f%%)" % [
		involving_receive, total, 100.0 * involving_receive / maxf(total, 1)])

	if receive_spells.is_empty():
		print("DIAG-CHURN: no RECEIVE spells recorded")
	else:
		receive_spells.sort()
		var sum := 0
		var one_or_two := 0
		for v in receive_spells:
			sum += v
			if v <= 2:
				one_or_two += 1
		print("DIAG-CHURN: %d RECEIVE spells; length min %d, median %d, max %d frames, mean %.1f" % [
			receive_spells.size(), receive_spells[0],
			receive_spells[receive_spells.size() / 2],
			receive_spells[receive_spells.size() - 1],
			float(sum) / receive_spells.size()])
		print("DIAG-CHURN:   spells lasting 1-2 frames (i.e. flicker): %d of %d (%.0f%%)" % [
			one_or_two, receive_spells.size(),
			100.0 * one_or_two / receive_spells.size()])
	get_tree().quit()


func _name(d) -> String:
	var i: int = int(d)
	return DUTY_NAMES[i] if i >= 0 and i < DUTY_NAMES.size() else "?%d" % i
