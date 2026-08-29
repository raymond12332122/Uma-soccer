extends Node3D

## v0.9.1.1: what does the AI actually CHOOSE over a live match?
##
## The scenario battery proves the decision logic is correct in seven
## constructed situations. It cannot prove those situations arise, or that the
## mix of actions over ninety seconds of emergent football looks like
## football. The rendered playtest showed 34 passes and ONE shot in 45s, which
## is either "chances are rare" or "shots are being suppressed" -- and those
## need telling apart.
##
## Taps decision_made on every player and tallies what was chosen, against
## what the situation was worth.

const MainScene := preload("res://scenes/Main.tscn")

const SECONDS := 90

var _counts := {"SHOOT": 0, "PASS": 0, "DRIBBLE": 0}
## Chances that were genuinely good, by what was chosen with them.
var _good_chance := {"SHOOT": 0, "PASS": 0, "DRIBBLE": 0}
var _backward_passes := 0
var _backward_with_good_chance := 0
var _opportunities: Array = []
var _best_missed: Array = []


func _ready() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(120):
		await get_tree().physics_frame

	for p in main.home_players + main.away_players:
		p.decision_made.connect(_on_decision)

	for i in range(SECONDS * 60):
		await get_tree().physics_frame

	var total: int = _counts["SHOOT"] + _counts["PASS"] + _counts["DRIBBLE"]
	print("DIAG-MIX: %d decisions over %ds" % [total, SECONDS])
	if total == 0:
		get_tree().quit()
		return
	for k in ["SHOOT", "PASS", "DRIBBLE"]:
		print("DIAG-MIX:   %-8s %5d (%.0f%%)" % [k, _counts[k], 100.0 * _counts[k] / total])

	_opportunities.sort()
	var n: int = _opportunities.size()
	if n > 0:
		print("DIAG-MIX: scoring opportunity across all decisions -- median %.3f, p90 %.3f, max %.3f" % [
			_opportunities[n / 2], _opportunities[int(n * 0.9)], _opportunities[n - 1]])
	var good: int = _good_chance["SHOOT"] + _good_chance["PASS"] + _good_chance["DRIBBLE"]
	print("DIAG-MIX: decisions taken with a GOOD chance on (opportunity >= %.2f): %d" % [
		AIController.HIGH_OPPORTUNITY, good])
	if good > 0:
		for k in ["SHOOT", "PASS", "DRIBBLE"]:
			print("DIAG-MIX:   with a good chance, chose %-8s %d (%.0f%%)" % [
				k, _good_chance[k], 100.0 * _good_chance[k] / good])
	print("DIAG-MIX: backward passes %d, of which %d were played with a good chance on  <-- the QA complaint" % [
		_backward_passes, _backward_with_good_chance])

	if not _best_missed.is_empty():
		print("DIAG-MIX: the best chances NOT shot:")
		_best_missed.sort_custom(func(a, b): return a["opportunity"] > b["opportunity"])
		for m in _best_missed.slice(0, 5):
			print("DIAG-MIX:   opportunity %.2f at %.1fm/%.0fdeg -> chose %s (%s)" % [
				m["opportunity"], m["dist"], m["angle"], m["chosen"], m["reason"]])
	get_tree().quit()


func _on_decision(info: Dictionary) -> void:
	var chosen: String = info.get("chosen", "")
	if not _counts.has(chosen):
		return
	_counts[chosen] += 1
	var opp: float = info.get("opportunity", 0.0)
	_opportunities.append(opp)
	if opp >= AIController.HIGH_OPPORTUNITY:
		_good_chance[chosen] += 1
		if chosen != "SHOOT":
			_best_missed.append({
				"opportunity": opp,
				"dist": info.get("dist_to_goal", 0.0),
				"angle": info.get("angle_to_goal", 0.0),
				"chosen": chosen,
				"reason": info.get("chosen_reason", ""),
			})
	if chosen == "PASS":
		for o in info.get("options", []):
			if o.get("action") == "PASS" and o.get("progress", 0.0) < 0.0:
				_backward_passes += 1
				if opp >= AIController.HIGH_OPPORTUNITY:
					_backward_with_good_chance += 1
