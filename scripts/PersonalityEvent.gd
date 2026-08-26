class_name PersonalityEvent
extends RefCounted

## One reusable "trigger -> probability -> condition -> behavior ->
## duration -> cooldown" definition. This class only stores data and
## Callables -- it has no state of its own. Per-player runtime state
## (which event is active, time left, per-event cooldowns) lives on
## FootballPlayer; PersonalityEventSystem is what evaluates these
## definitions against that state each frame.
##
## Adding a new character-specific behavior later means adding one more
## PersonalityEvent to scripts/data/PersonalityEvents.gd -- nothing about
## this class, PersonalityEventSystem, AIController, or FootballPlayer
## needs to change.

var id: String
## Callable(player: FootballPlayer, ctx: PersonalityContext) -> bool
var trigger_check: Callable
## Callable(player: FootballPlayer) -> bool -- personality/character gate,
## independent of match state.
var applies_to: Callable
## Chance per second this event starts, while trigger_check holds, gate
## passes, and the player is off cooldown for this event.
var probability_per_second: float
var duration: float
var cooldown: float
## Callable(player: FootballPlayer, ctx: PersonalityContext) -> void, called once when the event starts.
var on_start: Callable
## Callable(player: FootballPlayer, delta: float, ctx: PersonalityContext) -> void, called every frame while active.
var on_tick: Callable
## Callable(player: FootballPlayer, ctx: PersonalityContext) -> void, called once when the event ends (including forced early ends). Optional.
var on_end: Callable
## Optional AnimationController.play_action() name fired once on start.
var animation_action: String = ""


func _init(
	p_id: String,
	p_applies_to: Callable,
	p_trigger_check: Callable,
	p_probability_per_second: float,
	p_duration: float,
	p_cooldown: float,
	p_on_tick: Callable,
	p_on_start: Callable = Callable(),
	p_on_end: Callable = Callable(),
	p_animation_action: String = ""
) -> void:
	id = p_id
	applies_to = p_applies_to
	trigger_check = p_trigger_check
	probability_per_second = p_probability_per_second
	duration = p_duration
	cooldown = p_cooldown
	on_tick = p_on_tick
	on_start = p_on_start
	on_end = p_on_end
	animation_action = p_animation_action
