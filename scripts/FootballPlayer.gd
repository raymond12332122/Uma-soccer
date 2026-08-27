class_name FootballPlayer
extends CharacterBody3D

## Reusable entity for every player on the pitch -- human-controlled,
## AI-controlled, or goalkeeper. This script owns movement/dribbling/
## kicking simulation only. It never reads Input or InputState directly;
## exactly one driver (PlayerController for the human, or TeamController/
## AIController for everyone else) writes into the intent fields below
## each physics frame, and this script simulates the result.

# ---- Identity / team ----
@export var player_data: PlayerData
@export var team_id: int = 0
@export var is_goalkeeper: bool = false

## Behavioral tendencies, separate from player_data's football-ability
## stats. Looked up from PersonalityProfiles by visual_id in
## apply_player_data(); read by AIController (continuous decisions) and
## PersonalityEventSystem (spontaneous events). Never null after
## apply_player_data runs -- an unmatched key resolves to a neutral
## (all-50) default profile.
var personality: PersonalityData = PersonalityData.new()

## Normalized formation slot (see FormationManager), assigned by
## MatchManager at spawn time and used by TeamController/AIController and
## match-reset logic to know where this player belongs.
var formation_slot: Vector2 = Vector2.ZERO

## Specific formation role code (e.g. "CB", "LW", "ST"; "GK" for the
## goalkeeper), assigned by MatchManager alongside formation_slot. Read by
## AIController via FormationManager.role_category() for generic (never
## character-specific) team-shape behavior. Empty string for any player
## not spawned through a formation (e.g. a test-constructed FootballPlayer)
## -- FormationManager.role_category("") safely falls back to "MID".
var formation_role: String = ""

## Other players on this match, wired once by MatchManager right after
## both squads are spawned (set_match_context). Used only for the pass-
## direction assist in execute_pass()/_get_pass_direction() below -- never
## mutated per-frame, so this is cheap to keep as a plain reference.
var teammates: Array = []
var opponents: Array = []

## Wired once by MatchManager alongside set_match_context. Used only to
## resolve contested-ball duels generically (see _update_possession) --
## never read for anything else here.
var possession_manager: PossessionManager = null

# ---- Intent, written externally each physics frame ----
var move_input: Vector2 = Vector2.ZERO
var sprint_requested: bool = false
var pass_requested: bool = false
var shoot_held: bool = false

# ---- Movement tunables (defaults; overridden by player_data in apply_player_data) ----
var base_speed: float = 5.0
var sprint_speed: float = 8.5
@export var acceleration: float = 14.0
@export var deceleration: float = 20.0
@export var turn_lerp_speed: float = 12.0
@export var gravity: float = 20.0

@export var stamina_drain_rate: float = 18.0
@export var stamina_regen_rate: float = 10.0
var max_stamina: float = 100.0
var current_stamina: float = 100.0

# ---- Ball control / dribbling ----
# v0.8.2: the ball now hugs close at walking pace (dribble_distance) and
# is knocked a bit further ahead while sprinting (dribble_distance_sprint,
# see _update_possession) -- a fixed close-control leash regardless of
# speed was the whole ball -- and the spring itself is gentler (lower
# accel/damping/clamp than v0.8.1's 24/9/30) so the ball trails and
# settles naturally on a turn instead of snapping rigidly onto the target
# point every frame, which is what read as "welded to the player".
@export var dribble_distance: float = 0.62
@export var dribble_distance_sprint: float = 1.05
var dribble_accel: float = 13.0
@export var dribble_damping_accel: float = 6.0
@export var dribble_force_accel_clamp: float = 18.0
var control_loss_angle_threshold: float = 1.2
@export var control_loss_speed_threshold: float = 2.5
@export var control_loss_duration: float = 0.35
@export var possession_release_cooldown: float = 0.35
## How long has_possession survives the ball leaving the control radius
## when it was NOT deliberately kicked away -- see _update_possession.
## Short enough that a real dispossession still registers promptly.
const POSSESSION_GRACE := 0.15

# ---- Pass / Shoot ----
# v0.8.2: raised versus v0.8.1 (was 1.4-2.6 pass / 3.0-4.6 shoot) -- passes
# were dying out well short of teammates at realistic pitch distances
# against the ball's linear_damp. The two ranges still never overlap.
var pass_power: float = 2.8
var shoot_min_power: float = 4.2
var shoot_max_power: float = 7.6
@export var shoot_charge_time: float = 1.1
@export var kick_lift: float = 0.35
@export var momentum_transfer: float = 0.25

# ---- Pass assist tunables (see _get_pass_direction / _find_pass_target) ----
const PASS_ASSIST_MAX_DISTANCE := 26.0
const PASS_ASSIST_MIN_ALIGNMENT := 0.25  ## cos(~75deg) -- candidate must be roughly ahead of the aim direction
const PASS_ASSIST_BLEND := 0.7           ## 0 = pure raw aim, 1 = dead-on at the chosen teammate
const PASS_OBSTRUCTION_RADIUS := 1.3     ## opponent within this perpendicular distance of the lane counts as blocking it
## AIController's pass search uses this instead of PASS_ASSIST_MIN_ALIGNMENT
## -- an AI carrier's "aim" is usually just "toward goal" (see
## _get_aim_direction), which would otherwise exclude the very common case
## of an open teammate square or slightly behind them. The human PASS
## button intentionally keeps the tighter, direction-of-joystick cone
## instead -- that one really is meant to be "aim your pass".
const PASS_SEARCH_MIN_ALIGNMENT_OMNI := -1.0

@onready var action_area: Area3D = $ActionArea
@onready var control_area: Area3D = $ControlArea
@onready var model: Node3D = $Model
@onready var animation_controller: AnimationController = $Model/AnimationController
@onready var name_label: Label3D = $NameLabel
@onready var control_indicator: MeshInstance3D = $ControlIndicator

var ball_in_action_range: RigidBody3D = null
var ball_in_control_range: RigidBody3D = null

var has_possession: bool = false
var _facing_angle: float = 0.0

## The single authoritative movement intent AIController resolved for this
## player on its most recent update, recorded for diagnostics, the F3
## debug overlay, and regression tests (a test cannot assert "the target
## stayed stable" without being able to see the target). ai_state is an
## AIController.AIState value, -1 before any AI update has run.
## Human-controlled players keep whatever the AI last wrote -- they aren't
## driven by AIController at all, so these simply go stale, which is fine
## because nothing reads them for a human-controlled player.
var ai_state: int = -1
var ai_target: Vector3 = Vector3.ZERO
## Seconds the current ai_state has been held -- drives the shape-state
## dwell rule in AIController._determine_state (see MIN_SHAPE_STATE_DWELL).
var ai_state_time: float = 0.0

## v0.8.2: set/cleared exclusively by MatchManager during its brief
## PRE_MATCH/KICKOFF hold. Deliberately a flag FootballPlayer itself
## checks (rather than MatchManager just zeroing move_input each frame)
## -- PlayerController and TeamController both also write move_input every
## single tick, and MatchManager's own _physics_process runs before its
## children's in Godot's traversal order, so a plain "zero it out" write
## from MatchManager was immediately overwritten later the very same tick
## by whichever controller runs next, never actually reaching
## move_and_slide() at all. This flag has exactly one writer and it's
## read directly at the top of the movement calculation below, so there's
## no ordering race to lose.
var movement_locked: bool = false

## Set each physics frame in _physics_process -- whether this player was
## actually sprinting (requesting it, moving, and had stamina left) this
## tick, for the HUD's sprint indicator to read on the controlled player.
var is_currently_sprinting: bool = false

var _control_lost_timer: float = 0.0
var _possession_cooldown_timer: float = 0.0
var _possession_grace_timer: float = 0.0

var _shoot_charging: bool = false
var _shoot_charge_elapsed: float = 0.0

# ---- Personality bookkeeping (state only -- decisions live in
# PersonalityEventSystem / AIController, never here) ----

## Currently active personality event id, or "" if none. Set/cleared by
## PersonalityEventSystem; TeamController checks this (indirectly, via
## PersonalityEventSystem.tick()'s return value) to know whether to skip
## normal AI for this player this frame.
var active_personality_event: String = ""
var personality_event_time_left: float = 0.0
## event id -> seconds remaining before it can be considered again.
var personality_event_cooldowns: Dictionary = {}
## Scratch space an event's on_start/on_tick can stash data in (e.g. a
## wander target); cleared automatically whenever a new event starts.
var personality_scratch: Dictionary = {}
## Non-empty while an active event wants a specific AnimationController
## *state* (as opposed to a one-shot action) -- e.g. "sitting". Checked by
## _update_animation_state() before the normal speed-based computation.
var personality_visual_state_override: String = ""

var time_since_last_touch: float = 0.0
## Countdown windows (seconds) that stay >0 briefly after a momentary
## event, so PersonalityEventSystem's per-second probability roll gets a
## real chance to catch it instead of needing to hit an exact single
## physics frame.
var just_lost_possession_window: float = 0.0
var just_missed_shot_window: float = 0.0
var _pending_shot_check_timer: float = -1.0
const _SHOT_MISS_CHECK_DELAY := 1.5
const _MOMENTARY_TRIGGER_WINDOW := 0.6


func _ready() -> void:
	action_area.body_entered.connect(_on_action_area_entered)
	action_area.body_exited.connect(_on_action_area_exited)
	control_area.body_entered.connect(_on_control_area_entered)
	control_area.body_exited.connect(_on_control_area_exited)

	if player_data:
		apply_player_data(player_data)

	if control_indicator:
		control_indicator.visible = false


func apply_player_data(data: PlayerData) -> void:
	player_data = data
	base_speed = data.movement_speed
	sprint_speed = data.sprint_speed
	acceleration = data.acceleration

	max_stamina = data.stamina
	current_stamina = max_stamina

	# v0.8.1: pass and shoot power ranges no longer overlap at all (old
	# 1.6-3.2 pass vs. 2.4-4.2 shoot could put a high-passing player's tap
	# ahead of a low-shooting player's release) -- a pass should always
	# read as clearly weaker than any shot, never coincidentally similar.
	pass_power = lerp(1.4, 2.6, data.passing / 100.0)
	shoot_min_power = lerp(3.0, 4.6, data.shooting / 100.0)
	shoot_max_power = lerp(5.0, 8.5, data.shooting / 100.0)
	dribble_accel = lerp(16.0, 30.0, data.dribbling / 100.0)
	control_loss_angle_threshold = lerp(0.9, 1.5, data.dribbling / 100.0)

	if name_label:
		name_label.text = data.display_name

	if animation_controller:
		animation_controller.set_visual(data.visual_id)

	personality = PersonalityProfiles.get_profile(data.visual_id)

	if control_area:
		var shape_node: CollisionShape3D = control_area.get_node("CollisionShape3D")
		if shape_node and shape_node.shape:
			var shape: SphereShape3D = shape_node.shape.duplicate()
			shape.radius = lerp(0.95, 1.35, data.defensive_ability / 100.0)
			shape_node.shape = shape


## Wired once by MatchManager right after both squads are spawned. Safe to
## call again later (e.g. if a roster were ever rebuilt) -- just replaces
## the references.
func set_match_context(p_teammates: Array, p_opponents: Array) -> void:
	teammates = p_teammates
	opponents = p_opponents


## Wired once by MatchManager right after PossessionManager is created.
func set_possession_manager(pm: PossessionManager) -> void:
	possession_manager = pm


func set_team_color(color: Color) -> void:
	if animation_controller:
		animation_controller.set_team_color(color)


## Name labels stay hidden for every AI player by default (22 of them
## floating permanently is pure clutter) -- only the controlled player
## gets a name marker, alongside the ring indicator underfoot.
func set_controlled_visual(is_controlled: bool) -> void:
	if control_indicator:
		control_indicator.visible = is_controlled
	if name_label:
		name_label.visible = is_controlled


## Called by PossessionManager when this player wins the ball away from an
## opponent (as opposed to picking up a loose ball) -- a reasonable, cheap
## proxy for "successfully tackled" without a dedicated tackle mechanic.
func notify_possession_won_from_opponent() -> void:
	if animation_controller == null:
		return
	# A notably competitive/aggressive character reacts more visibly to
	# winning the ball than a plain "tackle" animation implies.
	if personality.competitiveness > 75.0 or personality.aggression > 75.0:
		animation_controller.play_action("excited_reaction")
	else:
		animation_controller.play_action("tackle")


## Called by MatchManager on every player of the scoring team after a goal.
## Plain default celebration -- react_to_goal() below decides whether a
## personality trait upgrades this to something more specific instead.
func play_celebration() -> void:
	if animation_controller:
		animation_controller.play_action("celebration")


## Called by MatchManager for every player after a goal (both teams), each
## frame after play_celebration() has already been called for the scoring
## side. This is the single authority on which pulse actually ends up
## playing (AnimationController's pulse system holds only one action at a
## time, so layering two calls would just mean the second silently wins)
## -- every branch below is a *replacement* choice, not an addition.
## Never touches gameplay state, purely a visual/animation decision.
func react_to_goal(scored_by_own_team: bool) -> void:
	if animation_controller == null:
		return

	if scored_by_own_team:
		if personality.showmanship > 70.0:
			animation_controller.play_action("victory_pose")
		elif personality.playfulness > 70.0:
			animation_controller.play_action("excited_reaction")
		# else: leave play_celebration()'s "celebration" pulse in place.
	else:
		if personality.composure < 45.0:
			animation_controller.play_action("frustrated_reaction")


## 0.0 when not charging a shot, otherwise how far through the charge
## window (0..1) -- read by the HUD to fill the SHOOT button's charge ring.
func get_shoot_charge_ratio() -> float:
	if not _shoot_charging or shoot_charge_time <= 0.0:
		return 0.0
	return clampf(_shoot_charge_elapsed / shoot_charge_time, 0.0, 1.0)


func has_active_personality_event() -> bool:
	return active_personality_event != ""


## Snapshot of this player's current AI-relevant state, for the debug
## overlay and for tests -- never used by gameplay logic itself.
func get_debug_info() -> Dictionary:
	return {
		"id": player_data.id if player_data else "",
		"name": player_data.display_name if player_data else "?",
		"visual_id": player_data.visual_id if player_data else "",
		"team_id": team_id,
		"formation_role": formation_role,
		"is_goalkeeper": is_goalkeeper,
		"has_possession": has_possession,
		"active_personality_event": active_personality_event,
		"personality_event_time_left": personality_event_time_left,
		"stamina_ratio": (current_stamina / max_stamina) if max_stamina > 0.0 else 0.0,
		"move_input": move_input,
		"sprint_requested": sprint_requested,
	}


## Clears all input intent and cancels any in-progress shot charge. Called
## when a player stops being human-controlled so it doesn't keep coasting
## on stale input or fire a phantom shot mid-charge. Also clears any
## active personality event (but NOT its cooldown) so switching to a
## player mid-event, or a match restart, never leaves a human-controlled
## character stuck sitting/wandering or an AI character frozen in a
## stale event from before the reset.
func reset_intent() -> void:
	move_input = Vector2.ZERO
	sprint_requested = false
	shoot_held = false
	pass_requested = false
	_shoot_charging = false
	_shoot_charge_elapsed = 0.0

	# A stale held AI state must not survive a switch/restart -- otherwise
	# the dwell rule could keep a player committed to a shape decision
	# made before the reset (see AIController.MIN_SHAPE_STATE_DWELL).
	ai_state = -1
	ai_state_time = 0.0

	active_personality_event = ""
	personality_event_time_left = 0.0
	personality_visual_state_override = ""
	personality_scratch.clear()
	just_lost_possession_window = 0.0
	just_missed_shot_window = 0.0
	_pending_shot_check_timer = -1.0


func _physics_process(delta: float) -> void:
	var wants_sprint: bool = (not movement_locked) and sprint_requested and move_input.length() > 0.1
	var sprinting: bool = wants_sprint and current_stamina > 0.0
	is_currently_sprinting = sprinting

	if sprinting:
		current_stamina = maxf(0.0, current_stamina - stamina_drain_rate * delta)
	else:
		current_stamina = minf(max_stamina, current_stamina + stamina_regen_rate * delta)

	# Fatigue scales sprint speed, acceleration, and (in _update_possession)
	# close control gradually as stamina drains, instead of a hard on/off
	# cliff at exactly 0 stamina -- a tired player is progressively less
	# sharp, not "full speed until empty, then frozen." At full stamina
	# (stamina_ratio == 1.0) every lerp below resolves to its old fixed
	# value, so a fresh player behaves exactly as before this system existed.
	var stamina_ratio: float = (current_stamina / max_stamina) if max_stamina > 0.0 else 1.0
	var sprint_bonus: float = (sprint_speed - base_speed) * lerp(0.4, 1.0, stamina_ratio)
	var target_speed: float = (base_speed + sprint_bonus) if sprinting else base_speed
	var effective_acceleration: float = acceleration * lerp(0.7, 1.0, stamina_ratio)
	var direction := Vector3.ZERO if movement_locked else Vector3(move_input.x, 0.0, move_input.y)

	if direction.length() > 0.01:
		var target_angle := atan2(direction.x, direction.z)
		var angle_delta := absf(wrapf(target_angle - _facing_angle, -PI, PI))
		var angle_threshold := control_loss_angle_threshold * (0.7 if sprinting else 1.0)

		if has_possession and _control_lost_timer <= 0.0 and angle_delta > angle_threshold and velocity.length() > control_loss_speed_threshold:
			_control_lost_timer = control_loss_duration

		_facing_angle = target_angle
		model.rotation.y = lerp_angle(model.rotation.y, _facing_angle, turn_lerp_speed * delta)

		velocity.x = move_toward(velocity.x, direction.x * target_speed, effective_acceleration * delta)
		velocity.z = move_toward(velocity.z, direction.z * target_speed, effective_acceleration * delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, deceleration * delta)
		velocity.z = move_toward(velocity.z, 0.0, deceleration * delta)

	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= gravity * delta

	move_and_slide()

	_update_possession(sprinting, stamina_ratio)
	_process_pass_input()
	_process_shoot_input(delta)
	_update_animation_state()
	_update_personality_bookkeeping(delta)

	if _control_lost_timer > 0.0:
		_control_lost_timer = maxf(0.0, _control_lost_timer - delta)
	if _possession_cooldown_timer > 0.0:
		_possession_cooldown_timer = maxf(0.0, _possession_cooldown_timer - delta)
	if _possession_grace_timer > 0.0:
		_possession_grace_timer = maxf(0.0, _possession_grace_timer - delta)


## Pure bookkeeping for personality triggers -- no gameplay decisions are
## made here, only timers/counters that PersonalityEvents' trigger_check
## Callables read. Safe to run every frame regardless of who/what is
## controlling this player.
func _update_personality_bookkeeping(delta: float) -> void:
	time_since_last_touch += delta

	if just_lost_possession_window > 0.0:
		just_lost_possession_window = maxf(0.0, just_lost_possession_window - delta)
	if just_missed_shot_window > 0.0:
		just_missed_shot_window = maxf(0.0, just_missed_shot_window - delta)

	# Heuristic, not true shot-outcome tracking: if a shot was taken and
	# this player still doesn't have the ball back by the time the check
	# fires, treat it as "didn't immediately work out" for reaction
	# purposes. Deliberately approximate and cosmetic-only -- it only ever
	# feeds a brief animation reaction, never blocks or delays anything
	# gameplay-relevant (goal detection, possession, restart all run
	# independently of this).
	if _pending_shot_check_timer > 0.0:
		_pending_shot_check_timer -= delta
		if _pending_shot_check_timer <= 0.0:
			_pending_shot_check_timer = -1.0
			if not has_possession:
				just_missed_shot_window = _MOMENTARY_TRIGGER_WINDOW


func _update_animation_state() -> void:
	if animation_controller == null:
		return
	if personality_visual_state_override != "":
		animation_controller.set_state(personality_visual_state_override)
		return
	var speed: float = Vector2(velocity.x, velocity.z).length()
	var state: String
	if speed < 0.3:
		state = "idle"
	elif has_possession:
		state = "dribble"
	elif speed >= sprint_speed * 0.85:
		state = "sprint"
	elif speed >= base_speed * 0.6:
		state = "run"
	else:
		state = "walk"
	animation_controller.set_state(state)


func _get_aim_direction() -> Vector3:
	if move_input.length() > 0.15:
		return Vector3(move_input.x, 0.0, move_input.y).normalized()
	return Vector3(sin(_facing_angle), 0.0, cos(_facing_angle))


# Soft-attach steering: nudges the ball toward a point just ahead of the
# player with a spring/damper force. The ball stays a fully simulated
# RigidBody3D at all times -- this only adds a force on top of normal
# physics, so collisions, bounces, and knock-aways still behave naturally.
func _update_possession(sprinting: bool, stamina_ratio: float = 1.0) -> void:
	# A deliberate kick always ends possession instantly (the cooldown is
	# set by _apply_kick_impulse) -- the grace below is only for a ball
	# jittering at the edge of the control radius, never for one the
	# player just played away on purpose.
	if _possession_cooldown_timer > 0.0:
		has_possession = false
		_possession_grace_timer = 0.0
		return

	if ball_in_control_range == null:
		# v0.8.2 hotfix: brief grace instead of dropping possession the
		# instant the ball crosses the control radius. Without it,
		# has_possession chattered frame-to-frame for a player in the act
		# of winning the ball, and because that flag selects between two
		# states with violently opposing targets -- HOLDING_POSSESSION
		# aims at the opponent goal, PRESSING aims at the ball underfoot
		# -- the contesting player's movement intent flipped through a
		# ~40m swing on consecutive frames. Diagnostics caught this as a
		# literal one-frame PRESSING->HOLDING_POSSESSION->PRESSING loop.
		# Everything downstream of has_possession (PossessionManager's
		# carrier election, the contested-ball steering gate, the AI
		# state machine) gets a steadier signal as a result.
		if has_possession and _possession_grace_timer > 0.0:
			return
		# Possession genuinely ends here (grace expired, and this wasn't a
		# deliberate kick -- that path returned above on the cooldown), so
		# this is the correct place to arm the "lost possession"
		# personality trigger. Firing it the instant the ball crossed the
		# radius instead would cry wolf on every touch the grace absorbs.
		if has_possession:
			just_lost_possession_window = _MOMENTARY_TRIGGER_WINDOW
		has_possession = false
		return

	_possession_grace_timer = POSSESSION_GRACE
	has_possession = true

	if _control_lost_timer > 0.0:
		return

	# Contested-ball fix: has_possession above is purely local (sensor
	# range + cooldown), so two opposing players standing in the same
	# ball's control range both used to reach this point and apply
	# opposing spring/damper forces every frame -- their pulls and
	# dampers cancel out at equilibrium, freezing the ball in place
	# until one side physically shoved it clear. PossessionManager
	# already elects a single carrier generically (closest, with
	# hysteresis so it doesn't flicker) -- once it has done so, only
	# that elected carrier actively steers the ball. The loser applies
	# no steering force at all, so there is never a second opposing
	# force to cancel against; the ball still responds normally to
	# both players' physical capsule collisions, so a contest still
	# looks/feels physical rather than the ball going inert. On the
	# rare first frame of a brand new contest (before PossessionManager
	# has run this tick and elected anyone), current_carrier can briefly
	# be null/stale for one frame -- harmless, self-corrects next tick.
	if possession_manager and possession_manager.current_carrier != null and possession_manager.current_carrier != self:
		return

	# Close control also degrades gradually with fatigue (weaker steering
	# force back to the target dribble point) -- at full stamina this is
	# identical to the pre-fatigue behavior.
	var accel_coeff: float = dribble_accel * lerp(0.75, 1.0, stamina_ratio)
	var damping_coeff := dribble_damping_accel
	if sprinting:
		accel_coeff *= 0.6
		damping_coeff *= 0.7

	# Close at a standstill/walk, knocked further ahead while sprinting --
	# "sprinting should loosen control" per the brief -- driven off actual
	# current speed (not just the sprinting flag) so the transition itself
	# feels smooth rather than an instant step.
	var speed_ratio: float = clampf(velocity.length() / maxf(sprint_speed, 0.01), 0.0, 1.0)
	var current_dribble_distance: float = lerp(dribble_distance, dribble_distance_sprint, speed_ratio)

	var facing_dir := Vector3(sin(_facing_angle), 0.0, cos(_facing_angle))
	var target_pos: Vector3 = global_position + facing_dir * current_dribble_distance

	var to_target: Vector3 = target_pos - ball_in_control_range.global_position
	to_target.y = 0.0

	var ball_vel: Vector3 = ball_in_control_range.linear_velocity
	var horizontal_vel := Vector3(ball_vel.x, 0.0, ball_vel.z)

	var accel_total: Vector3 = to_target * accel_coeff - horizontal_vel * damping_coeff
	accel_total = accel_total.limit_length(dribble_force_accel_clamp)

	ball_in_control_range.apply_central_force(accel_total * ball_in_control_range.mass)


func _process_pass_input() -> void:
	if not pass_requested:
		return
	pass_requested = false
	execute_pass()


## Only accumulates charge time while held -- firing on release is handled
## exclusively by notify_shoot_release() (see InputState.gd's doc comment
## and PlayerController), not here. A charge that never actually fires
## (e.g. reset_intent() on a player-switch mid-charge) just harmlessly
## stops accumulating.
func _process_shoot_input(delta: float) -> void:
	if shoot_held:
		if not _shoot_charging:
			_shoot_charging = true
			_shoot_charge_elapsed = 0.0
		else:
			_shoot_charge_elapsed = minf(_shoot_charge_elapsed + delta, shoot_charge_time)


## Single, exclusive firing point for a human-controlled release (touch or
## keyboard -- see PlayerController), called with the real wall-clock
## elapsed hold time. Prefers the frame-accumulated _shoot_charge_elapsed
## when this player was actually seen charging (the normal multi-frame
## hold case); falls back to the raw elapsed time when it wasn't -- a very
## fast tap can have its press *and* release both land inside the same
## physics-tick gap, so _process_shoot_input() above never got a chance to
## even set _shoot_charging, and a plain "was _shoot_charging true"
## release check would silently swallow the whole tap.
func notify_shoot_release(elapsed_seconds: float) -> void:
	var was_charging: bool = _shoot_charging
	_shoot_charging = false
	var charge_seconds: float = _shoot_charge_elapsed if was_charging else elapsed_seconds
	_shoot_charge_elapsed = 0.0
	var ratio: float = clampf(charge_seconds / shoot_charge_time, 0.0, 1.0) if shoot_charge_time > 0.0 else 1.0
	execute_shot(ratio)


## Public kick API -- used by the human charge-release flow above and
## called directly by AIController for AI-driven passes/shots. Falls back
## to the tighter control-range ball reference when the wider action-range
## one is momentarily null (e.g. a contest/possession handoff nudged the
## ball just outside the action sensor for a frame while still well within
## dribbling reach) -- action_area is a strict superset of control_area,
## so this only ever makes a real, close-by ball MORE kickable, never
## invents one that isn't actually there.
## min_alignment/forward_axis are forwarded straight to _find_pass_target
## (via _get_pass_direction) -- AIController's decision search and the
## actual kick direction here must agree, or the AI could decide to pass
## based on an omnidirectional search finding a square/backward teammate,
## then kick using the default narrow forward-only cone that excludes
## that exact same teammate and silently fall back to aiming at nothing
## in particular.
func execute_pass(min_alignment: float = PASS_ASSIST_MIN_ALIGNMENT, forward_axis: Vector3 = Vector3.ZERO) -> void:
	var ball: RigidBody3D = ball_in_action_range if ball_in_action_range else ball_in_control_range
	if ball == null:
		return
	_apply_kick_impulse(ball, pass_power, false, _get_pass_direction(min_alignment, forward_axis))


func execute_shot(charge_ratio: float) -> void:
	var ball: RigidBody3D = ball_in_action_range if ball_in_action_range else ball_in_control_range
	if ball == null:
		return
	var power: float = lerp(shoot_min_power, shoot_max_power, clampf(charge_ratio, 0.0, 1.0))
	_apply_kick_impulse(ball, power, true)


## Default aim direction, nudged toward a nearby, roughly-ahead, unblocked
## teammate if one exists (see _find_pass_target) -- a blend, not a snap,
## so "the default direction remains based on player aim/movement" holds:
## with no suitable candidate, or none set up via set_match_context() at
## all (teammates defaults to []), this returns the exact same direction
## passing always used before this system existed.
func _get_pass_direction(min_alignment: float = PASS_ASSIST_MIN_ALIGNMENT, forward_axis: Vector3 = Vector3.ZERO) -> Vector3:
	var base_dir: Vector3 = _get_aim_direction()
	var best: FootballPlayer = _find_pass_target(base_dir, min_alignment, forward_axis)
	if best == null:
		return base_dir
	var to_best: Vector3 = best.global_position - global_position
	to_best.y = 0.0
	if to_best.length() < 0.01:
		return base_dir
	return base_dir.slerp(to_best.normalized(), PASS_ASSIST_BLEND).normalized()


## v0.8.1: role-based small tie-breaker for _find_pass_target -- a more
## advanced teammate is a marginally more useful outlet than a deeper one
## when the rest of the score is close, without ever overriding alignment/
## openness/lane (still just a few hundredths, same spirit as the
## distance term below). GK is deprioritized slightly since passing back
## to your own keeper is rarely the attacking-useful option. Generic by
## role category only -- never a specific character or team.
const _PASS_ROLE_BONUS := {"FWD": 0.15, "MID": 0.05, "DEF": 0.0, "GK": -0.3}

## Among teammates roughly ahead of base_dir and within range, prefer one
## with a clear lane (no opponent close to the straight line between here
## and them), who is open (no opponent marking them closely), who is in a
## more advanced role, and who represents real forward progress -- "avoid
## passing directly through opponents when a reasonable alternative
## exists" without full auto-targeting (a candidate outside the alignment
## cone is never considered at all, regardless of how open they are).
## teammates naturally includes whichever player is currently
## human-controlled, same as every other teammate -- there is nothing
## here that special-cases the human.
##
## min_alignment overrides PASS_ASSIST_MIN_ALIGNMENT -- the human PASS
## button keeps the tight "aim your pass" cone (the default), but
## AIController's own search passes PASS_SEARCH_MIN_ALIGNMENT_OMNI: an AI
## carrier's "aim" is just whichever way they're currently running (see
## _get_aim_direction), almost always straight at goal, so a tight cone
## around that would exclude the extremely common case of an open
## teammate square or slightly behind them -- alignment still *scores*
## positively below, it just stops being a hard filter.
##
## forward_axis (when non-zero) adds a small bonus for genuine progression
## up the pitch, independent of base_dir -- "a pass should have a purpose"
## (progression being one of them) rather than only ever describing where
## the passer happened to be aiming.
func _find_pass_target(base_dir: Vector3, min_alignment: float = PASS_ASSIST_MIN_ALIGNMENT, forward_axis: Vector3 = Vector3.ZERO) -> FootballPlayer:
	var best: FootballPlayer = null
	var best_score := -INF
	var base_dir_n: Vector3 = base_dir.normalized()
	var forward_axis_n: Vector3 = forward_axis.normalized() if forward_axis != Vector3.ZERO else Vector3.ZERO

	for mate in teammates:
		if mate == self or mate == null or not is_instance_valid(mate):
			continue
		var to_mate: Vector3 = mate.global_position - global_position
		to_mate.y = 0.0
		var dist: float = to_mate.length()
		if dist < 0.5 or dist > PASS_ASSIST_MAX_DISTANCE:
			continue
		var to_mate_dir: Vector3 = to_mate / dist
		var alignment: float = base_dir_n.dot(to_mate_dir)
		if alignment < min_alignment:
			continue
		var score: float = alignment - dist * 0.01
		if _lane_is_obstructed(to_mate, dist):
			score -= 0.5
		score -= (1.0 - _openness(mate)) * 0.4
		score += _PASS_ROLE_BONUS.get(FormationManager.role_category(mate.formation_role), 0.0)
		if forward_axis_n != Vector3.ZERO:
			score += forward_axis_n.dot(to_mate_dir) * 0.3
		if score > best_score:
			best_score = score
			best = mate
	return best


## 1.0 = no opponent within OPENNESS_FULL_RADIUS of this teammate (fully
## open), scaling down to 0.0 as the nearest marker closes in -- a cheap,
## generic proxy for "is this teammate actually a good pass target right
## now" that doesn't need real vision/line-of-sight simulation.
const OPENNESS_FULL_RADIUS := 6.0

func _openness(mate: FootballPlayer) -> float:
	var nearest := INF
	for opp in opponents:
		if opp == null or not is_instance_valid(opp):
			continue
		var d: float = mate.global_position.distance_to(opp.global_position)
		if d < nearest:
			nearest = d
	if nearest == INF:
		return 1.0
	return clampf(nearest / OPENNESS_FULL_RADIUS, 0.0, 1.0)


func _lane_is_obstructed(to_mate: Vector3, dist: float) -> bool:
	var dir: Vector3 = to_mate / dist
	for opp in opponents:
		if opp == null or not is_instance_valid(opp):
			continue
		var to_opp: Vector3 = opp.global_position - global_position
		to_opp.y = 0.0
		var along: float = to_opp.dot(dir)
		if along <= 0.3 or along >= dist - 0.3:
			continue
		var perp: Vector3 = to_opp - dir * along
		if perp.length() < PASS_OBSTRUCTION_RADIUS:
			return true
	return false


func _apply_kick_impulse(ball: RigidBody3D, power: float, is_shot: bool, aim_dir_override: Vector3 = Vector3.ZERO) -> void:
	var aim_dir: Vector3 = aim_dir_override if aim_dir_override != Vector3.ZERO else _get_aim_direction()
	var impulse: Vector3 = aim_dir * power + velocity * momentum_transfer
	impulse.y = kick_lift * (1.0 if is_shot else 0.6)

	ball.apply_central_impulse(impulse)

	has_possession = false
	_control_lost_timer = 0.0
	_possession_cooldown_timer = possession_release_cooldown
	time_since_last_touch = 0.0

	if is_shot:
		_pending_shot_check_timer = _SHOT_MISS_CHECK_DELAY

	if animation_controller:
		animation_controller.play_action("shoot" if is_shot else "pass")


func _on_action_area_entered(body: Node3D) -> void:
	if body is RigidBody3D and body.is_in_group("ball"):
		ball_in_action_range = body


func _on_action_area_exited(body: Node3D) -> void:
	if body == ball_in_action_range:
		ball_in_action_range = null


func _on_control_area_entered(body: Node3D) -> void:
	if body is RigidBody3D and body.is_in_group("ball"):
		ball_in_control_range = body


## Only drops the ball reference -- whether that actually ends possession
## is _update_possession's call alone (it applies POSSESSION_GRACE first),
## so there is exactly one place that clears has_possession. Clearing it
## here too would defeat the grace, since the ball crossing the control
## radius is precisely the event the grace exists to absorb.
func _on_control_area_exited(body: Node3D) -> void:
	if body == ball_in_control_range:
		ball_in_control_range = null
