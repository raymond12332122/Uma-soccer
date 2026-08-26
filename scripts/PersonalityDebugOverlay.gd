class_name PersonalityDebugOverlay
extends CanvasLayer

## Developer/debug display: current controlled character, its personality
## state, AI decision (move/sprint intent), active personality event +
## time left, possession state, and a compact per-player event summary so
## AI-controlled characters' events are visible too. Toggled with F3 (see
## MatchManager); fully inert (no processing, no visible node) until
## toggled on, so it never affects normal play.

var match_manager: Node = null

var _label: Label
var _visible: bool = false


func _ready() -> void:
	layer = 10
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 16)
	_label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_label.add_theme_constant_override("outline_size", 4)
	_label.position = Vector2(16, 90)
	_label.custom_minimum_size = Vector2(520, 0)
	add_child(_label)
	visible = false


func toggle_visible() -> void:
	_visible = not _visible
	visible = _visible


func _process(_delta: float) -> void:
	if not _visible or match_manager == null:
		return
	_label.text = _build_text()


func _build_text() -> String:
	var lines: Array[String] = []
	lines.append("[F3 debug] PersonalityDebugOverlay")

	var controlled: FootballPlayer = match_manager.player_controller.controlled_player if match_manager.player_controller else null
	if controlled:
		var info: Dictionary = controlled.get_debug_info()
		lines.append("Controlled: %s (%s)" % [info["name"], info["visual_id"]])
		lines.append("  possession: %s   move_input: %s   sprint: %s" % [info["has_possession"], info["move_input"], info["sprint_requested"]])
		lines.append("  stamina: %.0f%%   active event: %s (%.1fs left)" % [
			info["stamina_ratio"] * 100.0,
			info["active_personality_event"] if info["active_personality_event"] != "" else "-",
			info["personality_event_time_left"],
		])
		var p: PersonalityData = controlled.personality
		if p:
			lines.append("  traits: conf=%.0f disc=%.0f aggr=%.0f comp=%.0f play=%.0f risk=%.0f" % [
				p.confidence, p.discipline, p.aggression, p.composure, p.playfulness, p.risk_taking
			])

	if match_manager.possession_manager:
		var pm = match_manager.possession_manager
		lines.append("Ball: %s" % ("loose" if pm.is_loose else "team %d" % pm.possessing_team))

	lines.append("-- All players --")
	for player in match_manager.home_players + match_manager.away_players:
		if player == controlled:
			continue
		var ev: String = player.active_personality_event
		if ev != "":
			lines.append("  %s: %s (%.1fs)" % [player.player_data.display_name, ev, player.personality_event_time_left])

	lines.append("Force: call MatchManager.force_personality_event(player, event_id)")
	return "\n".join(lines)
