class_name PersonalityEventSystem
extends RefCounted

## Reusable personality-event engine. Definitions come from
## PersonalityEvents.build_events() (scripts/data/PersonalityEvents.gd);
## this class only evaluates them against per-player runtime state stored
## on FootballPlayer (active_personality_event, personality_event_time_left,
## personality_event_cooldowns).
##
## Usage per AI-controlled player, per physics frame, in this order:
##   1. tick()          -- advances/ends any currently active event.
##      If it returns true, the event drove this player's intent this
##      frame; the caller (TeamController) should skip normal AIController
##      logic for this player entirely.
##   2. (if tick() returned false) run normal AIController logic.
##   3. maybe_trigger()  -- rolls for a new event to start, so a
##      freshly-started event's own on_start isn't immediately overwritten
##      by this frame's AI output.
##
## Never called for the human-controlled player -- TeamController already
## excludes them from AI, and personality events follow the same
## exclusion, so they never steal control from a human.

var _events: Array = []


func _init() -> void:
	_events = PersonalityEvents.build_events()


func tick(player: FootballPlayer, delta: float, ctx: PersonalityContext) -> bool:
	if player.active_personality_event == "":
		return false

	var ev: PersonalityEvent = _find(player.active_personality_event)
	player.personality_event_time_left -= delta

	if ev == null or player.personality_event_time_left <= 0.0:
		_end_event(player, ev, ctx)
		return false

	if ev.on_tick.is_valid():
		ev.on_tick.call(player, delta, ctx)
	return true


func maybe_trigger(player: FootballPlayer, delta: float, ctx: PersonalityContext) -> void:
	for key in player.personality_event_cooldowns.keys():
		player.personality_event_cooldowns[key] = maxf(0.0, player.personality_event_cooldowns[key] - delta)

	for ev in _events:
		if player.personality_event_cooldowns.get(ev.id, 0.0) > 0.0:
			continue
		if not ev.applies_to.call(player):
			continue
		if not ev.trigger_check.call(player, ctx):
			continue
		if randf() < ev.probability_per_second * delta:
			_start_event(player, ev, ctx)
			return


## Debug/test hook: force-start a specific event on a player immediately,
## bypassing the probability roll and (by default) the trigger check, but
## still respecting the personality gate unless force_bypass_gates is
## true. Used by the debug overlay's forced-event command and by tests
## that need a deterministic event without waiting on RNG.
func force_trigger(player: FootballPlayer, event_id: String, ctx: PersonalityContext, force_bypass_gates: bool = true) -> bool:
	var ev: PersonalityEvent = _find(event_id)
	if ev == null:
		return false
	if not force_bypass_gates and not ev.applies_to.call(player):
		return false
	_start_event(player, ev, ctx)
	return true


func get_event(event_id: String) -> PersonalityEvent:
	return _find(event_id)


func all_event_ids() -> Array:
	var ids: Array = []
	for ev in _events:
		ids.append(ev.id)
	return ids


func _start_event(player: FootballPlayer, ev: PersonalityEvent, ctx: PersonalityContext) -> void:
	player.active_personality_event = ev.id
	player.personality_event_time_left = ev.duration
	player.personality_event_cooldowns[ev.id] = ev.duration + ev.cooldown
	player.personality_scratch.clear()
	if ev.on_start.is_valid():
		ev.on_start.call(player, ctx)
	if ev.animation_action != "" and player.animation_controller:
		player.animation_controller.play_action(ev.animation_action)


func _end_event(player: FootballPlayer, ev: PersonalityEvent, ctx: PersonalityContext) -> void:
	if ev and ev.on_end.is_valid():
		ev.on_end.call(player, ctx)
	player.active_personality_event = ""
	player.personality_event_time_left = 0.0
	player.personality_visual_state_override = ""


func _find(event_id: String) -> PersonalityEvent:
	for ev in _events:
		if ev.id == event_id:
			return ev
	return null
