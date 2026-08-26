class_name PersonalityEvents
extends RefCounted

## Concrete personality event definitions. Fan-game interpretations, not
## claims about official game mechanics. Adding a new character-specific
## behavior later is one more PersonalityEvent appended in build_events()
## -- nothing about PersonalityEventSystem, AIController, or
## FootballPlayer needs to change for it.
##
## Two gating styles are used on purpose:
##   - id-gated (applies_to checks player_data.visual_id): for behaviors
##     the design brief calls out as THAT character's specific signature
##     (Gold Ship's chaos, Opera O's showboating, Agnes's reaction to a
##     specific teammate).
##   - trait-gated (applies_to checks personality thresholds): for more
##     general behaviors any sufficiently low-composure/poor-stamina-
##     management/etc. character would exhibit, demonstrating the system
##     generalizes beyond one-off special cases.

const WANDER_RADIUS := 4.0
const NEAR_MIDFIELD_X := 6.0
const EXHAUSTED_RATIO := 0.25


static func build_events() -> Array:
	return [
		PersonalityEvent.new(
			"gold_ship_bored_sit",
			Callable(PersonalityEvents, "_gate_gold_ship"),
			Callable(PersonalityEvents, "_trigger_calm_and_uninvolved"),
			0.02, 5.0, 75.0,
			Callable(PersonalityEvents, "_tick_sit"),
			Callable(), Callable(),
			"look_around"
		),
		PersonalityEvent.new(
			"gold_ship_wander_off",
			Callable(PersonalityEvents, "_gate_gold_ship"),
			Callable(PersonalityEvents, "_trigger_calm_and_uninvolved"),
			0.015, 5.0, 80.0,
			Callable(PersonalityEvents, "_tick_wander"),
			Callable(PersonalityEvents, "_start_wander"), Callable(),
			"look_around"
		),
		PersonalityEvent.new(
			"gold_ship_sudden_sprint",
			Callable(PersonalityEvents, "_gate_gold_ship"),
			Callable(PersonalityEvents, "_trigger_ball_in_moderate_range"),
			0.01, 3.0, 50.0,
			Callable(PersonalityEvents, "_tick_sprint_to_ball"),
		),
		PersonalityEvent.new(
			"opera_o_showboat",
			Callable(PersonalityEvents, "_gate_opera_o"),
			Callable(PersonalityEvents, "_trigger_attacking_third_with_ball"),
			0.02, 1.2, 40.0,
			Callable(PersonalityEvents, "_tick_showboat"),
		),
		PersonalityEvent.new(
			"agnes_excited_near_teio",
			Callable(PersonalityEvents, "_gate_agnes"),
			Callable(PersonalityEvents, "_trigger_near_teio_and_exciting"),
			0.03, 1.5, 45.0,
			Callable(PersonalityEvents, "_tick_pause"),
			Callable(), Callable(),
			"excited_reaction"
		),
		PersonalityEvent.new(
			"exhausted_ease_off",
			Callable(PersonalityEvents, "_gate_poor_stamina_management"),
			Callable(PersonalityEvents, "_trigger_exhausted_and_calm"),
			0.05, 4.0, 30.0,
			Callable(PersonalityEvents, "_tick_ease_off"),
		),
		PersonalityEvent.new(
			"lost_possession_frustration",
			Callable(PersonalityEvents, "_gate_low_composure"),
			Callable(PersonalityEvents, "_trigger_just_lost_possession"),
			0.6, 0.8, 20.0,
			Callable(PersonalityEvents, "_tick_pause"),
			Callable(), Callable(),
			"frustrated_reaction"
		),
		PersonalityEvent.new(
			"missed_shot_reaction",
			Callable(PersonalityEvents, "_gate_low_confidence_or_composure"),
			Callable(PersonalityEvents, "_trigger_just_missed_shot"),
			0.6, 0.8, 20.0,
			Callable(PersonalityEvents, "_tick_pause"),
			Callable(), Callable(),
			"frustrated_reaction"
		),
	]


# ---- Gates (applies_to: Callable(player) -> bool) ----

static func _gate_gold_ship(player: FootballPlayer) -> bool:
	return player.player_data != null and player.player_data.visual_id == "gold_ship"


static func _gate_opera_o(player: FootballPlayer) -> bool:
	return player.player_data != null and player.player_data.visual_id == "tm_opera_o"


static func _gate_agnes(player: FootballPlayer) -> bool:
	return player.player_data != null and player.player_data.visual_id == "agnes_digital"


static func _gate_poor_stamina_management(player: FootballPlayer) -> bool:
	return player.personality != null and player.personality.stamina_management < 40.0


static func _gate_low_composure(player: FootballPlayer) -> bool:
	return player.personality != null and player.personality.composure < 45.0


static func _gate_low_confidence_or_composure(player: FootballPlayer) -> bool:
	if player.personality == null:
		return false
	return player.personality.confidence < 55.0 or player.personality.composure < 45.0


# ---- Triggers (trigger_check: Callable(player, ctx) -> bool) ----

static func _trigger_calm_and_uninvolved(player: FootballPlayer, ctx: PersonalityContext) -> bool:
	if not ctx.mood.is_calm():
		return false
	if player.has_possession:
		return false
	if ctx.ball == null:
		return false
	return player.global_position.distance_to(ctx.ball.global_position) > 6.0


static func _trigger_ball_in_moderate_range(player: FootballPlayer, ctx: PersonalityContext) -> bool:
	if player.has_possession or ctx.ball == null:
		return false
	var d: float = player.global_position.distance_to(ctx.ball.global_position)
	return d > 10.0 and d < 30.0


static func _trigger_attacking_third_with_ball(player: FootballPlayer, ctx: PersonalityContext) -> bool:
	if not player.has_possession:
		return false
	return player.global_position.distance_to(ctx.opponent_goal_pos) < 14.0


static func _trigger_near_teio_and_exciting(player: FootballPlayer, ctx: PersonalityContext) -> bool:
	if ctx.mood.is_calm():
		return false
	var teio: FootballPlayer = null
	for mate in ctx.teammates:
		if mate.player_data != null and mate.player_data.visual_id == "tokai_teio":
			teio = mate
			break
	if teio == null or teio == player:
		return false
	return player.global_position.distance_to(teio.global_position) < 6.0


static func _trigger_exhausted_and_calm(player: FootballPlayer, ctx: PersonalityContext) -> bool:
	if not ctx.mood.is_calm():
		return false
	if player.max_stamina <= 0.0:
		return false
	return (player.current_stamina / player.max_stamina) < EXHAUSTED_RATIO


static func _trigger_just_lost_possession(player: FootballPlayer, _ctx: PersonalityContext) -> bool:
	return player.just_lost_possession_window > 0.0


static func _trigger_just_missed_shot(player: FootballPlayer, _ctx: PersonalityContext) -> bool:
	return player.just_missed_shot_window > 0.0


# ---- Behaviors (on_start / on_tick: Callable(player, [delta,] ctx) -> void) ----

static func _start_wander(player: FootballPlayer, _ctx: PersonalityContext) -> void:
	var offset := Vector3(randf_range(-WANDER_RADIUS, WANDER_RADIUS), 0.0, randf_range(-WANDER_RADIUS, WANDER_RADIUS))
	player.personality_scratch["wander_target"] = player.global_position + offset


static func _tick_sit(player: FootballPlayer, _delta: float, _ctx: PersonalityContext) -> void:
	player.move_input = Vector2.ZERO
	player.sprint_requested = false
	player.personality_visual_state_override = "sitting"


static func _tick_wander(player: FootballPlayer, _delta: float, _ctx: PersonalityContext) -> void:
	var target: Vector3 = player.personality_scratch.get("wander_target", player.global_position)
	AIController._move_toward(player, target, 0.5)
	player.sprint_requested = false


static func _tick_sprint_to_ball(player: FootballPlayer, _delta: float, ctx: PersonalityContext) -> void:
	if ctx.ball == null:
		return
	AIController._move_toward(player, ctx.ball.global_position, 0.6)
	player.sprint_requested = true


static func _tick_showboat(player: FootballPlayer, _delta: float, ctx: PersonalityContext) -> void:
	AIController._move_toward(player, ctx.opponent_goal_pos, 0.6)
	player.sprint_requested = false


static func _tick_ease_off(player: FootballPlayer, _delta: float, _ctx: PersonalityContext) -> void:
	player.sprint_requested = false
	player.move_input = player.move_input * 0.5


static func _tick_pause(player: FootballPlayer, _delta: float, _ctx: PersonalityContext) -> void:
	player.move_input = Vector2.ZERO
	player.sprint_requested = false
