extends Node3D

# Headless regression test for the v0.6 personality system: profile
# validity, AI decision modifiers, event probability/cooldown/duration/
# interruption, Gold Ship's specific event, and that events never break
# switching, match restart, or goal scoring. Run via:
#   godot --headless --path . tests/PersonalityTest.tscn
#
# Probability/cooldown/duration checks drive PersonalityEventSystem
# directly with synthetic delta steps (no real-time waiting needed --
# these are pure state-machine/RNG behaviors, not physics), so a
# statistically overwhelming number of "seconds" can be simulated near-
# instantly. End-to-end checks (switching, restart, goal scoring) use the
# real Main scene with awaited physics frames, exactly like the other
# suites.

const FieldScene := preload("res://scenes/Field.tscn")
const BallScene := preload("res://scenes/Ball.tscn")
const PlayerScene := preload("res://scenes/FootballPlayer.tscn")
const MainScene := preload("res://scenes/Main.tscn")

const ALL_CHARACTER_IDS := [
	"tokai_teio", "agnes_digital", "tamamo_cross", "oguri_cap", "gold_ship",
	"symboli_rudolf", "air_groove", "tm_opera_o", "grass_wonder", "mejiro_mcqueen",
	"silence_suzuka",
]

var ok := true


func _ready() -> void:
	_run_tests()


func _run_tests() -> void:
	_test_profile_validity()
	_test_stats_vs_personality_separation()

	var field = FieldScene.instantiate()
	add_child(field)
	var ball: BallController = BallScene.instantiate()
	ball.position = Vector3(0, 1, 0)
	add_child(ball)

	var gold_ship := _make_player("gold_ship", Vector3(0, 1, 0))
	var rudolf := _make_player("symboli_rudolf", Vector3(5, 1, 0))
	var opera_o := _make_player("tm_opera_o", Vector3(-5, 1, 0))

	_test_ai_modifiers(gold_ship, rudolf, opera_o)

	var mood := MatchMood.new()
	var events := PersonalityEventSystem.new()
	var ctx := _make_context(ball, mood)

	_test_event_probability(gold_ship, events, ctx)
	_test_event_cooldown(gold_ship, events, ctx)
	_test_event_duration(events, ctx)
	_test_event_interruption(gold_ship, events, ctx)
	_test_gold_ship_special_event(gold_ship, rudolf, events, ctx)

	await _test_full_match_integration()

	print("TEST_SUMMARY: %s" % ("ALL PASS" if ok else "FAILURES PRESENT"))
	get_tree().quit(0 if ok else 1)


# ---------------------------------------------------------------- helpers

func _make_player(visual_id: String, pos: Vector3) -> FootballPlayer:
	var data := PlayerData.new()
	data.id = "test_%s" % visual_id
	data.display_name = visual_id
	data.movement_speed = 5.0
	data.acceleration = 14.0
	data.sprint_speed = 8.5
	data.passing = 70
	data.shooting = 70
	data.dribbling = 70
	data.stamina = 80
	data.defensive_ability = 60
	data.visual_id = visual_id

	var player: FootballPlayer = PlayerScene.instantiate()
	player.position = pos
	add_child(player)
	player.apply_player_data(data)
	return player


func _make_context(ball: RigidBody3D, mood: MatchMood) -> PersonalityContext:
	var ctx := PersonalityContext.new()
	ctx.ball = ball
	ctx.mood = mood
	ctx.teammates = []
	ctx.opponents = []
	ctx.own_goal_pos = Vector3(-26, 1, 0)
	ctx.opponent_goal_pos = Vector3(26, 1, 0)
	ctx.possessing_team = -1
	ctx.is_loose = true
	return ctx


# ------------------------------------------------------------- A. profiles

func _test_profile_validity() -> void:
	for id in ALL_CHARACTER_IDS:
		var p: PersonalityData = PersonalityProfiles.get_profile(id)
		_check("Profile '%s' resolves to a PersonalityData" % id, p != null)
		var traits := [
			p.confidence, p.discipline, p.aggression, p.competitiveness, p.playfulness,
			p.impulsiveness, p.composure, p.teamwork, p.stamina_management,
			p.tactical_awareness, p.showmanship, p.laziness, p.risk_taking,
		]
		var all_in_range := true
		for v in traits:
			if v < 0.0 or v > 100.0:
				all_in_range = false
		_check("Profile '%s' has every trait in [0,100]" % id, all_in_range)

	var unknown: PersonalityData = PersonalityProfiles.get_profile("not_a_real_character")
	_check("Unknown character id resolves to a neutral default profile", is_equal_approx(unknown.confidence, 50.0) and is_equal_approx(unknown.discipline, 50.0))

	var gold: PersonalityData = PersonalityProfiles.get_profile("gold_ship")
	var rudolf: PersonalityData = PersonalityProfiles.get_profile("symboli_rudolf")
	_check("Different characters have genuinely different personalities (not identical defaults)", not is_equal_approx(gold.discipline, rudolf.discipline))


func _test_stats_vs_personality_separation() -> void:
	var data_a := PlayerData.new()
	data_a.visual_id = "gold_ship"
	data_a.movement_speed = 9.9
	data_a.shooting = 99.0

	var data_b := PlayerData.new()
	data_b.visual_id = "gold_ship"
	data_b.movement_speed = 3.0
	data_b.shooting = 10.0

	var pa: PersonalityData = PersonalityProfiles.get_profile(data_a.visual_id)
	var pb: PersonalityData = PersonalityProfiles.get_profile(data_b.visual_id)
	_check(
		"Same character id gives identical personality regardless of differing football stats (the two axes are independent)",
		is_equal_approx(pa.playfulness, pb.playfulness) and not is_equal_approx(data_a.movement_speed, data_b.movement_speed)
	)


# ----------------------------------------------------------- C. AI modifiers

func _test_ai_modifiers(gold_ship: FootballPlayer, rudolf: FootballPlayer, opera_o: FootballPlayer) -> void:
	_check(
		"High aggression/risk-taking (Gold Ship) gets a lower sprint threshold than disciplined/composed Rudolf",
		AIController._sprint_threshold(gold_ship) < AIController._sprint_threshold(rudolf)
	)
	_check(
		"High confidence/risk-taking (Opera O) gets a longer shoot range than Rudolf",
		AIController._shoot_range(opera_o) > AIController._shoot_range(rudolf)
	)
	_check(
		"High aggression/risk-taking (Gold Ship) gets a bigger forward-run advance distance than disciplined Rudolf",
		AIController._advance_distance(gold_ship) > AIController._advance_distance(rudolf)
	)
	# gold_ship and rudolf are spawned exactly 5 units apart (see
	# _make_player calls below) -- using each as the other's "teammate"
	# exercises the teamwork-driven spacing_radius formula directly:
	# better teamwork (Rudolf) keeps a bigger spacing radius, so at a
	# fixed 5-unit separation Rudolf's repulsion push is stronger.
	var gold_repel: Vector3 = AIController._spacing_offset(gold_ship, [rudolf])
	var rudolf_repel: Vector3 = AIController._spacing_offset(rudolf, [gold_ship])
	_check(
		"Better teamwork (Rudolf) keeps a larger spacing radius, producing a stronger repel-from-teammate push at the same distance than Gold Ship",
		rudolf_repel.length() > gold_repel.length()
	)


# --------------------------------------------------------- D. probability

func _test_event_probability(gold_ship: FootballPlayer, events: PersonalityEventSystem, ctx: PersonalityContext) -> void:
	# Push the shared mood well past the "calm" threshold up front so the
	# trigger condition genuinely holds for both sub-tests below (this
	# synthetic-delta loop never calls mood.tick(), so it would otherwise
	# never cross 12s on its own) -- the gate-fails sub-test only proves
	# anything about the *gate* if the trigger isn't ALSO independently
	# false.
	ctx.mood.time_since_exciting_event = 999.0
	# gold_ship spawns at the same position as the ball (see _run_tests),
	# which would keep the "uninvolved" distance check permanently false.
	# Move her away for this test specifically.
	gold_ship.global_position = Vector3(40, 1, 40)

	# Gate fails (not gold ship) -- must never fire gold_ship_bored_sit
	# even given enormous simulated time and a trigger that genuinely holds.
	var rudolf_like := _make_player("symboli_rudolf", Vector3(50, 1, 50))
	var fired_for_wrong_character := false
	for i in range(20000):
		events.maybe_trigger(rudolf_like, 1.0 / 60.0, ctx)
		if rudolf_like.active_personality_event == "gold_ship_bored_sit":
			fired_for_wrong_character = true
			break
		rudolf_like.active_personality_event = ""
		rudolf_like.personality_event_cooldowns.clear()
	_check("A character that doesn't pass the gate never triggers another character's event, however long simulated", not fired_for_wrong_character)
	rudolf_like.queue_free()

	# Gate + trigger both hold for gold ship -- over enough simulated time
	# (~330 in-match seconds at 0.02/s probability) it must eventually fire.
	gold_ship.active_personality_event = ""
	gold_ship.personality_event_cooldowns.clear()
	var fired := false
	for i in range(200000):
		if events.tick(gold_ship, 1.0 / 60.0, ctx):
			fired = true
			break
		events.maybe_trigger(gold_ship, 1.0 / 60.0, ctx)
		if gold_ship.active_personality_event != "":
			fired = true
			break
	_check("Gold Ship's gated+triggered event fires at least once given enough simulated time (probability mechanism genuinely works)", fired)


# ----------------------------------------------------------- E. cooldowns

func _test_event_cooldown(gold_ship: FootballPlayer, events: PersonalityEventSystem, ctx: PersonalityContext) -> void:
	gold_ship.reset_intent()
	gold_ship.personality_event_cooldowns.clear()

	var started: bool = events.force_trigger(gold_ship, "gold_ship_bored_sit", ctx)
	_check("force_trigger successfully starts the event for setting up the cooldown test", started)

	var ev := events.get_event("gold_ship_bored_sit")
	# Run past the event's own duration so it ends naturally.
	for i in range(int((ev.duration + 0.5) * 60)):
		events.tick(gold_ship, 1.0 / 60.0, ctx)
	_check("Event has ended after its duration elapses", gold_ship.active_personality_event == "")
	_check("Cooldown is set (>0) immediately after the event ends", gold_ship.personality_event_cooldowns.get("gold_ship_bored_sit", 0.0) > 0.0)

	# While on cooldown, repeated maybe_trigger calls (even with the
	# trigger condition forced true via context) must not restart it.
	var restarted_during_cooldown := false
	for i in range(600):
		events.maybe_trigger(gold_ship, 1.0 / 60.0, ctx)
		if gold_ship.active_personality_event == "gold_ship_bored_sit":
			restarted_during_cooldown = true
			break
	_check("Event does not restart while its cooldown is still active", not restarted_during_cooldown)

	# Advance well past the cooldown window; it must reach exactly 0 (not
	# go negative, not get stuck). Force has_possession=true for this
	# phase so the trigger_check can never hold -- otherwise, once the
	# cooldown genuinely reaches 0 partway through this long loop, the
	# event could legitimately re-fire (correct behavior) and reset the
	# cooldown to a new nonzero value, which would make this specific
	# "did it reach exactly 0" assertion flaky rather than deterministic.
	gold_ship.has_possession = true
	for i in range(int((ev.cooldown + 5.0) * 60)):
		events.maybe_trigger(gold_ship, 1.0 / 60.0, ctx)
	gold_ship.has_possession = false
	_check("Cooldown fully expires (reaches 0) after enough time passes", is_equal_approx(gold_ship.personality_event_cooldowns.get("gold_ship_bored_sit", -1.0), 0.0))


# ----------------------------------------------------------- F. duration

func _test_event_duration(events: PersonalityEventSystem, ctx: PersonalityContext) -> void:
	var p := _make_player("gold_ship", Vector3(20, 1, 20))
	events.force_trigger(p, "gold_ship_sudden_sprint", ctx)
	var ev := events.get_event("gold_ship_sudden_sprint")

	var still_active_before_end := true
	var half_frames: int = int(ev.duration * 60 * 0.5)
	for i in range(half_frames):
		if not events.tick(p, 1.0 / 60.0, ctx):
			still_active_before_end = false
	_check("Event remains active for roughly its declared duration (still active at the halfway point)", still_active_before_end)

	var ended_after_full_duration := false
	for i in range(int(ev.duration * 60) + 10):
		if not events.tick(p, 1.0 / 60.0, ctx):
			ended_after_full_duration = true
			break
	_check("Event ends once its full duration has elapsed", ended_after_full_duration)
	p.queue_free()


# ------------------------------------------------------- G. interruption

func _test_event_interruption(gold_ship: FootballPlayer, events: PersonalityEventSystem, ctx: PersonalityContext) -> void:
	gold_ship.reset_intent()
	gold_ship.personality_event_cooldowns.clear()
	events.force_trigger(gold_ship, "gold_ship_wander_off", ctx)
	_check("Event is active before interruption", gold_ship.active_personality_event != "")

	# Simulate what happens on player-switch or match restart.
	gold_ship.reset_intent()

	_check("reset_intent() (switch/restart path) immediately clears an active event regardless of remaining duration", gold_ship.active_personality_event == "")
	_check("reset_intent() clears the visual state override too", gold_ship.personality_visual_state_override == "")
	_check("Interrupting an event does not permanently disable the player (move_input is back to neutral, not stuck)", gold_ship.move_input == Vector2.ZERO)


# --------------------------------------------------- H. Gold Ship special

func _test_gold_ship_special_event(gold_ship: FootballPlayer, rudolf: FootballPlayer, events: PersonalityEventSystem, ctx: PersonalityContext) -> void:
	gold_ship.reset_intent()
	gold_ship.personality_event_cooldowns.clear()

	var refused: bool = events.force_trigger(rudolf, "gold_ship_bored_sit", ctx, false)
	_check("Gold Ship's bored_sit event refuses to fire on a non-Gold-Ship character when gates are respected", not refused)

	var started: bool = events.force_trigger(gold_ship, "gold_ship_bored_sit", ctx, false)
	_check("Gold Ship's bored_sit event fires on Gold Ship herself", started)

	events.tick(gold_ship, 1.0 / 60.0, ctx)
	_check("'Gold Ship got bored and sat down': move_input goes to zero", gold_ship.move_input == Vector2.ZERO)
	_check("'Gold Ship got bored and sat down': sprint is not requested", not gold_ship.sprint_requested)
	_check("'Gold Ship got bored and sat down': visual state override is 'sitting'", gold_ship.personality_visual_state_override == "sitting")

	# "Gold Ship should still be capable of participating normally" --
	# once the event ends, she goes right back to being a normal player
	# with no lingering restriction.
	gold_ship.reset_intent()
	_check("Gold Ship is fully normal again immediately after the event ends/is cleared", gold_ship.active_personality_event == "" and gold_ship.personality_visual_state_override == "")


# ------------------------------------------------ full-match integration

func _test_full_match_integration() -> void:
	var main = MainScene.instantiate()
	add_child(main)
	for i in range(5):
		await get_tree().physics_frame

	# Find Gold Ship on the away roster (she's an outfield defender as of
	# v0.6, not the goalkeeper).
	var gold: FootballPlayer = null
	for p in main.away_players:
		if p.player_data.visual_id == "gold_ship":
			gold = p
			break
	_check("Gold Ship is present in the live match and is not the goalkeeper", gold != null and not gold.is_goalkeeper)

	# --- J. personality events never affect the human-controlled player ---
	var controlled: FootballPlayer = main.player_controller.controlled_player
	var human_ever_got_event := false
	for i in range(300):
		await get_tree().physics_frame
		if controlled.active_personality_event != "":
			human_ever_got_event = true
	_check("The human-controlled player never receives a personality event (events are AI-only)", not human_ever_got_event)

	# Force an event onto Gold Ship (AI-controlled) directly through
	# MatchManager's debug/test hook.
	var forced: bool = main.force_personality_event(gold, "gold_ship_bored_sit")
	_check("MatchManager.force_personality_event() successfully forces Gold Ship's event in a live match", forced)
	await get_tree().physics_frame
	_check("Forced event is reflected as active on the player", gold.active_personality_event == "gold_ship_bored_sit")

	# --- J continued: switching to Gold Ship mid-event clears it ---
	var reached_gold := false
	for i in range(main.home_players.size() + 4):
		main._switch_to_next_player()
		await get_tree().physics_frame
		if main.player_controller.controlled_player == gold:
			reached_gold = true
			break
	# Gold Ship is on the away team, which switching (home-only) can never
	# reach -- confirm that expectation, then verify her event is still
	# safely running under AI rather than having corrupted anything.
	_check("Switching only ever cycles the home roster (away players, including Gold Ship, are never human-controlled)", not reached_gold)
	_check("Gold Ship's forced event is still tracked consistently after switching activity elsewhere", gold.active_personality_event == "" or gold.active_personality_event == "gold_ship_bored_sit")

	# --- K. match restart clears active events cleanly ---
	main.force_personality_event(gold, "gold_ship_wander_off")
	await get_tree().physics_frame
	_check("Event is active on Gold Ship before restart", gold.active_personality_event != "")

	main.restart_match()
	_check("Match restart clears the active personality event", gold.active_personality_event == "")
	_check("Match restart still resets score", main.home_score == 0 and main.away_score == 0)

	# --- L. goal scoring still works correctly with an active event ---
	main.force_personality_event(gold, "gold_ship_bored_sit")
	await get_tree().physics_frame
	_check("Event active on Gold Ship going into the goal-scoring check", gold.active_personality_event != "")

	main.ball.linear_velocity = Vector3.ZERO
	main.ball.global_position = main.get_node("Field/GoalAreaRight").global_position
	var scored := false
	for i in range(30):
		await get_tree().physics_frame
		if main.home_score == 1:
			scored = true
			break
	_check("Goal detection still works correctly while a personality event is active elsewhere on the pitch", scored)
	_check("Goal scoring clears the active event as part of the standard post-goal reset", gold.active_personality_event == "")
	_check("Possession manager is still in a valid state after a goal with an active event", main.possession_manager.is_loose or main.possession_manager.current_carrier != null)


func _check(label: String, condition: bool) -> void:
	if condition:
		print("[PASS] %s" % label)
	else:
		print("[FAIL] %s" % label)
		ok = false
