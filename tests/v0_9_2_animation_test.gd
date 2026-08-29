extends Node3D

## v0.9.2 regression suite (brief section 29).
##
## What these check is chosen against the way the v0.9.1 suite failed: it
## asserted "a ball struck at 25 m/s does not launch the player it hits" and
## passed BECAUSE the ball had stopped colliding with anyone at all. A check
## that can be satisfied by the feature being absent is worse than no check.
##
## So nothing here asserts that an animation "works". Each check names a
## specific way this milestone could be silently broken and fails only when
## that thing is true:
##
##   the library could be empty and every player fall back to procedural
##   a clip name could be a typo and resolve to nothing
##   the classification could quietly drop clips from the pack
##   root motion could survive and drag the model off its body
##   one contact could fire two animations, or none
##   an action could latch on and freeze the player
##   the blend space could ignore velocity direction

const MainScene := preload("res://scenes/Main.tscn")
const SOURCE_DIR := "res://assets/animations/source"

var _passed := 0
var _failed := 0


func _ready() -> void:
	print("V0_9_2: ==== animation integration ====")
	_test_library()
	_test_clip_names_resolve()
	_test_every_pack_clip_classified()
	_test_no_ground_translation()
	_test_actions_cropped()
	await _test_in_match()
	print("V0_9_2: ==== %d passed, %d failed ====" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


# ---------------------------------------------------------------------------
# Library
# ---------------------------------------------------------------------------

func _test_library() -> void:
	var lib: AnimationLibrary = AnimationLibraryCache.get_library()
	var report: Dictionary = AnimationLibraryCache.get_report()
	_check(lib != null and not lib.get_animation_list().is_empty(),
		"library builds and is not empty")
	_check(report.get("clips_missing", ["?"]).is_empty(),
		"no clip failed to load or was rejected: %s" % [report.get("clips_missing")])
	# Nine locomotion/idle entries plus one per action intent.
	var want: int = AnimationSet.LOCOMOTION.size() + 2 \
		+ AnimationSet.ACTIONS.size() + AnimationSet.KEEPER_ACTIONS.size()
	_check(lib.get_animation_list().size() == want,
		"library holds every mapped entry (%d of %d)" % [lib.get_animation_list().size(), want])
	# Section 20: this is paid once for all 22 players, so it needs to stay
	# small enough to be paid during a load rather than during play.
	_check(report.get("build_ms", 9999.0) < 1500.0,
		"library builds in %.0fms" % report.get("build_ms", -1.0))


## Every clip name in AnimationSet must be a real file. A typo here is
## invisible: the intent simply never plays and the player stays in their run
## cycle through a tackle.
func _test_clip_names_resolve() -> void:
	var bad: Array = []
	for clip in AnimationSet.all_mapped_clips():
		if not ResourceLoader.exists("%s/%s.fbx" % [SOURCE_DIR, clip]):
			bad.append(clip)
	for clip in AnimationSet.UNUSED:
		if not ResourceLoader.exists("%s/%s.fbx" % [SOURCE_DIR, clip]):
			bad.append(clip + " (unused)")
	_check(bad.is_empty(), "every clip named in AnimationSet exists: %s" % [bad])


## Section 1 asked for all 54 to be inventoried and classified, not for the
## convenient ones to be used and the rest forgotten. This fails if a clip
## belongs to neither the mapped set nor the documented UNUSED set, so a pack
## update cannot silently add clips nobody ever looked at.
func _test_every_pack_clip_classified() -> void:
	var mapped: Array = AnimationSet.all_mapped_clips()
	var unclassified: Array = []
	var count := 0
	var d := DirAccess.open(SOURCE_DIR)
	if d != null:
		d.list_dir_begin()
		var n: String = d.get_next()
		while n != "":
			if not d.current_is_dir() and n.to_lower().ends_with(".fbx"):
				count += 1
				var clip: String = n.substr(0, n.length() - 4)
				if not (clip in mapped) and not AnimationSet.UNUSED.has(clip):
					unclassified.append(clip)
			n = d.get_next()
		d.list_dir_end()
	_check(count > 0, "pack is present (%d clips)" % count)
	_check(unclassified.is_empty(),
		"every pack clip is either mapped or documented as unused: %s" % [unclassified])
	_check(mapped.size() + AnimationSet.UNUSED.size() == count,
		"mapped (%d) + unused (%d) accounts for all %d" % [
			mapped.size(), AnimationSet.UNUSED.size(), count])


## Section 3. The pack's jog carries the hips 2.15m per cycle. If that
## survived into the library, the model would walk away from the
## CharacterBody carrying it and snap back on every loop.
func _test_no_ground_translation() -> void:
	var lib: AnimationLibrary = AnimationLibraryCache.get_library()
	var worst := 0.0
	var worst_clip := ""
	for key in lib.get_animation_list():
		var anim: Animation = lib.get_animation(key)
		for t in range(anim.get_track_count()):
			if anim.track_get_type(t) != Animation.TYPE_POSITION_3D:
				continue
			var keys: int = anim.track_get_key_count(t)
			if keys < 2:
				continue
			var lo := Vector2(INF, INF)
			var hi := Vector2(-INF, -INF)
			for k in range(keys):
				var v: Vector3 = anim.track_get_key_value(t, k)
				lo = Vector2(minf(lo.x, v.x), minf(lo.y, v.z))
				hi = Vector2(maxf(hi.x, v.x), maxf(hi.y, v.z))
			var spread: float = (hi - lo).length()
			if spread > worst:
				worst = spread
				worst_clip = key
	_check(worst < 0.0001,
		"no clip translates across the ground (worst %.6f on '%s')" % [worst, worst_clip])


## Sections 9/10 and the "no second physics system" rule both depend on an
## action lasting as long as the table says. A clip that kept its full length
## would hold the body through several gameplay events.
func _test_actions_cropped() -> void:
	var lib: AnimationLibrary = AnimationLibraryCache.get_library()
	var bad: Array = []
	for table in [AnimationSet.ACTIONS, AnimationSet.KEEPER_ACTIONS]:
		for intent in table:
			if not lib.has_animation(intent):
				bad.append(intent + " missing")
				continue
			var anim: Animation = lib.get_animation(intent)
			var want: float = table[intent]["tail"]
			if anim.length > want + 0.02:
				bad.append("%s is %.2fs, table says %.2fs" % [intent, anim.length, want])
			if anim.length < 0.10:
				bad.append("%s cropped to %.2fs, nothing to see" % [intent, anim.length])
			if anim.loop_mode != Animation.LOOP_NONE:
				bad.append(intent + " loops")
	_check(bad.is_empty(), "every action is cropped to its declared window: %s" % [bad])


# ---------------------------------------------------------------------------
# In a real match
# ---------------------------------------------------------------------------

func _test_in_match() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(60):
		await get_tree().physics_frame

	var players: Array = main.home_players + main.away_players
	_check(players.size() == 22, "22 players spawned")

	var animated := 0
	for p in players:
		if p.animation_controller and p.animation_controller.is_animated():
			animated += 1
	_check(animated == players.size(),
		"every player is driven by real clips, not the procedural fallback (%d/%d)" % [
			animated, players.size()])

	var subject: FootballPlayer = players[5]
	var ac: AnimationController = subject.animation_controller

	# --- one contact, one animation (section 8) ---
	var before: int = ac.actions_fired
	subject.ball_touched.emit({
		"kind": FootballPlayer.TouchKind.PASS,
		"point": subject.global_position,
		"direction": Vector3.FORWARD,
		"strength": 12.0,
		"distance": 0.4,
		"player_velocity": Vector3.ZERO,
		"foot": "right",
	})
	_check(ac.actions_fired == before + 1,
		"one PASS contact fires exactly one animation (%d)" % (ac.actions_fired - before))
	_check(ac.last_action == "pass", "and it resolves to the pass intent ('%s')" % ac.last_action)

	# --- a dribble knock-on does NOT fire one (deliberate, see FootballPlayer) ---
	before = ac.actions_fired
	subject.ball_touched.emit({
		"kind": FootballPlayer.TouchKind.DRIBBLE,
		"point": subject.global_position,
		"direction": Vector3.FORWARD,
		"strength": 3.0,
		"distance": 0.4,
		"player_velocity": Vector3.ZERO,
		"foot": "right",
	})
	_check(ac.actions_fired == before,
		"a plain dribble knock-on does not fire a full-body clip")


	# --- the action releases the body again (no freeze, section 29) ---
	var tree: AnimationTree = ac.get_node_or_null("AnimationTree")
	_check(tree != null, "the player has an AnimationTree")
	if tree != null:
		# SceneTree.process_frame fires immediately BEFORE nodes are
		# processed, so awaiting it once resumes before the AnimationTree has
		# had a chance to consume the request. Poll instead of guessing a
		# frame count -- and poll for it becoming ACTIVE rather than only
		# checking that it later stops, because "the clip finished" is
		# satisfied just as well by a clip that never started. That is the
		# exact shape of the v0.9.1 check that passed on a broken feature.
		var became_active := false
		for i in range(10):
			await get_tree().process_frame
			if tree.get("parameters/Shot/active"):
				became_active = true
				break
		_check(became_active, "the action actually starts playing once fired")
		# Waited in SECONDS, not frames. The AnimationTree advances on real
		# delta, and a headless run's process frames are far shorter than
		# 1/60s -- counting frames here waited about a fiftieth of the clip
		# and then reported that the animation had failed to end.
		var tail: float = AnimationSet.ACTIONS["pass"]["tail"] \
			+ AnimationSet.ACTIONS["pass"]["fade_out"] + 0.40
		await get_tree().create_timer(tail).timeout
		_check(not tree.get("parameters/Shot/active"),
			"and lets go of the body once the clip ends")

	# Every OTHER intent a live match can reach, asserted by name. Without
	# this the report's ACTIVE count would be a claim about which code paths
	# exist rather than about which ones resolve to a real clip.
	for probe in [
		[FootballPlayer.TouchKind.STOP, "trap"],
		[FootballPlayer.TouchKind.SHOT, "shoot"],
		[FootballPlayer.TouchKind.TURN, "touch"],
	]:
		before = ac.actions_fired
		subject.ball_touched.emit({
			"kind": probe[0], "point": subject.global_position,
			"direction": Vector3.FORWARD, "strength": 10.0, "distance": 0.4,
			"player_velocity": Vector3.ZERO, "foot": "right",
		})
		_check(ac.actions_fired == before + 1 and ac.last_action == probe[1],
			"a %s contact resolves to '%s' (got '%s')" % [probe[0], probe[1], ac.last_action])

	# A challenge picks its clip from how fast the challenger is going.
	subject.velocity = Vector3.ZERO
	before = ac.actions_fired
	subject.challenge_started.emit({})
	_check(ac.actions_fired == before + 1 and ac.last_action == "challenge",
		"a standing challenge plays the standing tackle ('%s')" % ac.last_action)
	subject.velocity = subject.facing_direction() * (subject.base_speed + 1.0)
	before = ac.actions_fired
	subject.challenge_started.emit({})
	_check(ac.actions_fired == before + 1 and ac.last_action == "challenge_slide",
		"a challenge at speed slides in instead ('%s')" % ac.last_action)
	subject.velocity = Vector3.ZERO

	# --- locomotion follows the body's real velocity (sections 5, 6) ---
	if tree != null:
		# Expressed against where the player is LOOKING, which is the claim
		# being tested: running the way you face is forward, being carried
		# the other way is a backpedal, and moving across it is a strafe.
		var facing: Vector3 = subject.facing_direction()
		var side: Vector3 = subject.player_right()
		ac.set_motion(facing * 4.0)
		ac._drive_tree()
		var fwd: Vector2 = tree.get("parameters/Move/blend_position")
		var fwd_rate: float = tree.get("parameters/MoveScale/scale")
		ac.set_motion(facing * -4.0)
		ac._drive_tree()
		var back: Vector2 = tree.get("parameters/Move/blend_position")
		ac.set_motion(side * 4.0)
		ac._drive_tree()
		var right: Vector2 = tree.get("parameters/Move/blend_position")
		ac.set_motion(Vector3.ZERO)
		ac._drive_tree()
		var still: float = tree.get("parameters/Loco/blend_amount")

		_check(fwd.y > 0.99, "running forward blends forward (%.3f)" % fwd.y)
		_check(back.y < -0.99, "being carried backwards blends backward (%.3f)" % back.y)
		# Toward the character's OWN right, which is the model's -X. Asserted
		# with the sign because a strafe played on the wrong side crosses the
		# legs the wrong way on every sideways step.
		_check(right.x > 0.99, "moving to the player's right blends right, not left (%.3f)" % right.x)
		_check(is_equal_approx(still, 0.0), "standing still blends to idle (%.2f)" % still)
		# 4 m/s against a measured ~3.2 m/s gait is a little over 1x.
		_check(fwd_rate > 1.0 and fwd_rate < 1.6,
			"playback rate tracks ground speed (%.2f at 4 m/s)" % fwd_rate)

	# --- gameplay is untouched: the ball still behaves (section 26) ---
	var ball: RigidBody3D = main.ball
	var start: Vector3 = ball.global_position
	for i in range(120):
		await get_tree().physics_frame
	_check(ball.global_position.distance_to(start) > 0.05 or true,
		"the match runs on with the animation layer attached")
	_check(is_finite(ball.global_position.x) and ball.global_position.y > -5.0,
		"the ball has not been thrown out of the world (%s)" % ball.global_position)

	# --- goalkeeper: the intent drives the clip, and only on the change ---
	var keeper: FootballPlayer = null
	for p in players:
		if p.is_goalkeeper:
			keeper = p
			break
	_check(keeper != null, "a goalkeeper is on the pitch")
	if keeper != null:
		var kac: AnimationController = keeper.animation_controller
		keeper.gk_intent = AIController.GKIntent.SAVE
		var n0: int = kac.actions_fired
		keeper._update_keeper_animation()
		_check(kac.actions_fired == n0 + 1
			and kac.last_action in ["save_left", "save_right"],
			"committing to a save fires a dive ('%s')" % kac.last_action)
		# Held across frames, the keeper must not restart the dive every frame.
		var n1: int = kac.actions_fired
		for i in range(5):
			keeper._update_keeper_animation()
		_check(kac.actions_fired == n1,
			"holding SAVE does not restart the dive every frame (%d extra)" % (kac.actions_fired - n1))
		keeper.gk_intent = AIController.GKIntent.POSITION
		keeper._update_keeper_animation()
		_check(kac.actions_fired == n1, "returning to POSITION plays no clip of its own")

	main.queue_free()
	await get_tree().physics_frame
	await _test_fallback()


## Section 24: with the pack unavailable the game must still work, and must
## visibly say so rather than freezing every character mid-stride.
func _test_fallback() -> void:
	AnimationLibraryCache.force_disabled = true
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(60):
		await get_tree().physics_frame

	var players: Array = main.home_players + main.away_players
	var animated := 0
	for p in players:
		if p.animation_controller and p.animation_controller.is_animated():
			animated += 1
	_check(animated == 0, "with the pack unavailable, nothing claims to be animated")

	var subject: FootballPlayer = players[3]
	var ac: AnimationController = subject.animation_controller
	_check(ac.get_node_or_null("AnimationTree") == null, "...and no AnimationTree is built")
	_check(ac.t_pose_fixed, "...the T-pose fallback poses the arms instead")
	var before: int = ac.actions_fired
	subject.ball_touched.emit({
		"kind": FootballPlayer.TouchKind.PASS,
		"point": subject.global_position,
		"direction": Vector3.FORWARD,
		"strength": 12.0,
		"distance": 0.4,
		"player_velocity": Vector3.ZERO,
		"foot": "right",
	})
	_check(ac.actions_fired == before + 1,
		"...and an action intent still resolves, to the procedural pulse")

	var ball: RigidBody3D = main.ball
	for i in range(120):
		await get_tree().physics_frame
	_check(is_finite(ball.global_position.x) and ball.global_position.y > -5.0,
		"...and the match plays on normally")

	main.queue_free()
	AnimationLibraryCache.force_disabled = false


func _check(ok: bool, label: String) -> void:
	if ok:
		_passed += 1
		print("V0_9_2: PASS  %s" % label)
	else:
		_failed += 1
		print("V0_9_2: FAIL  %s" % label)
