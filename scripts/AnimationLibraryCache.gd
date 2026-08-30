class_name AnimationLibraryCache
extends RefCounted

## v0.9.2: build ONE AnimationLibrary and share it across all 22 players
## (brief sections 3, 4, 20).
##
## Two things make this a build step rather than a load:
##
## 1. ROOT MOTION HAS TO GO (section 3). Every clip in the pack carries a hips
##    position track, and for the locomotion clips that track is the whole
##    gait's ground travel -- 'jog forward' moves the hips 2.15m over its
##    0.82s cycle. Played as authored, the model would walk 2.15m away from
##    the CharacterBody that is supposed to be carrying it and then snap back
##    on the loop. The CharacterBody is authoritative, so the horizontal part
##    of the hips track is flattened here and only the vertical bob is kept.
##    That is done ONCE, at build time, rather than by fighting it per frame.
##
## 2. THE CLIPS NEED CROPPING (sections 9, 10). A strike starts at its
##    measured contact frame because gameplay launches the ball with no
##    wind-up, and it is cut short so a 2.75s scissor kick cannot lock a
##    player's body for most of three seconds. Cropping at build time means
##    the runtime never needs a seek or an offset: the action clip simply
##    starts at zero and ends when it should.
##
## Sharing matters on mobile: 22 animated characters holding private copies of
## 38 clips would be 836 Animation resources. This builds 38 and hands the
## same library to every AnimationController. Only the AnimationTree state is
## per-player.

const SOURCE_DIR := "res://assets/animations/source"

static var _library: AnimationLibrary = null
## Populated by build(): what actually made it in, for the report's counts and
## for tests to assert against.
static var _report: Dictionary = {}

## Test/diagnostic lever: pretend the pack is absent.
##
## Section 24 asks for a working fallback when clips are unavailable, and the
## only honest way to know it works is to take them away and look. This is
## also what the performance diagnostic switches to get an A/B against the
## same match with no animation on it. Never set in shipped code.
static var force_disabled := false


## The shared library, built on first call. Null only if the pack is missing
## entirely, which AnimationController treats as "fall back to procedural".
static func get_library() -> AnimationLibrary:
	if force_disabled:
		return null
	if _library == null:
		_build()
	return _library


static func get_report() -> Dictionary:
	if _library == null:
		_build()
	return _report


static func _build() -> void:
	var lib := AnimationLibrary.new()
	var loaded: Array = []
	var missing: Array = []
	var t0: int = Time.get_ticks_usec()

	# --- locomotion: looped, ground travel removed ---
	for clip in AnimationSet.LOCOMOTION:
		var a: Animation = _load_clip(clip)
		if a == null:
			missing.append(clip)
			continue
		_flatten_ground_translation(a)
		a.loop_mode = Animation.LOOP_LINEAR
		if lib.add_animation(_key(clip), a) != OK:
			missing.append(clip + " (rejected)")
			continue
		loaded.append(clip)

	for clip in [AnimationSet.IDLE_CLIP, AnimationSet.IDLE_CLIP_KEEPER,
			AnimationSet.IDLE_CLIP_KEEPER_ALT]:
		var a: Animation = _load_clip(clip)
		if a == null:
			missing.append(clip)
			continue
		_flatten_ground_translation(a)
		a.loop_mode = Animation.LOOP_LINEAR
		if lib.add_animation(_key(clip), a) != OK:
			missing.append(clip + " (rejected)")
			continue
		loaded.append(clip)

	# --- actions: cropped to the window that is actually played ---
	#
	# Keyed by INTENT AND VARIANT, not by clip: several intents legitimately
	# offer more than one clip for variety, and two intents can share one
	# source file cut differently -- 'pass' and 'shoot' are both the penalty
	# kick, with a shorter and a longer follow-through.
	var action_keys: Array = []
	for intent in AnimationSet.INTENTS:
		var entry: Dictionary = AnimationSet.INTENTS[intent]
		var options: Array = entry["clips"]
		for i in range(options.size()):
			var opt: Dictionary = options[i]
			var a: Animation = _load_clip(opt["clip"])
			if a == null:
				missing.append(opt["clip"])
				continue
			_flatten_ground_translation(a)
			var start: float = opt["start"]
			if start == AnimationSet.WIND_UP:
				start = 0.0
			_crop(a, start, opt["tail"])
			a.loop_mode = Animation.LOOP_NONE
			var key: String = AnimationSet.variant_key(intent, i)
			if lib.add_animation(key, a) != OK:
				missing.append(key + " (rejected)")
				continue
			action_keys.append(key)
			if not (opt["clip"] in loaded):
				loaded.append(opt["clip"])

	_library = lib
	_report = {
		"clips_used": loaded.size(),
		"clips_missing": missing,
		"library_entries": lib.get_animation_list().size(),
		"action_intents": action_keys.size(),
		"build_ms": (Time.get_ticks_usec() - t0) / 1000.0,
	}


## Library key for a locomotion/idle clip. Action clips are keyed by INTENT,
## not by clip, because two intents legitimately share one source file with
## different crops -- 'pass' and 'shoot' are both cut from the penalty kick.
##
## Underscore, not slash: Godot reserves '/' in an animation name as the
## library separator and add_animation() rejects the name outright, which
## costs a library with every locomotion clip silently missing from it.
static func _key(clip: String) -> String:
	return "loco_" + clip


## Pull the single Animation out of one imported FBX.
##
## Every one of the 54 files names its clip 'mixamo_com', so the FILE is the
## identity and the internal clip name carries no information at all. The
## Animation is duplicated because the imported scene's copy is shared through
## the resource cache -- editing it in place would corrupt the source for
## anything else that loads it, including a later rebuild in the same session.
static func _load_clip(clip: String) -> Animation:
	var path: String = "%s/%s.fbx" % [SOURCE_DIR, clip]
	if not ResourceLoader.exists(path):
		return null
	var packed: PackedScene = load(path)
	if packed == null:
		return null
	var root: Node = packed.instantiate()
	var ap: AnimationPlayer = _find_ap(root)
	var out: Animation = null
	if ap != null and not ap.get_animation_list().is_empty():
		var src: Animation = ap.get_animation(ap.get_animation_list()[0])
		if src != null:
			out = src.duplicate(true)
	root.queue_free()
	return out


## Remove a clip's ground travel, keeping its vertical bob.
##
## The hips position track is rewritten so every key keeps its own Y but takes
## the FIRST key's X and Z. The character therefore still rises and falls with
## the stride -- which is what makes a run read as a run -- while going
## nowhere of its own accord. Section 3: the CharacterBody moves the player,
## the animation never does.
static func _flatten_ground_translation(anim: Animation) -> void:
	for t in range(anim.get_track_count()):
		if anim.track_get_type(t) != Animation.TYPE_POSITION_3D:
			continue
		var keys: int = anim.track_get_key_count(t)
		if keys == 0:
			continue
		var first: Vector3 = anim.track_get_key_value(t, 0)
		for k in range(keys):
			var v: Vector3 = anim.track_get_key_value(t, k)
			anim.track_set_key_value(t, k, Vector3(first.x, v.y, first.z))


## Keep only [start, start + length] of a clip, rebased so it begins at zero.
##
## Each track gets an interpolated key inserted at the new start so the crop
## does not begin mid-interval on whatever key happened to precede it; keys
## outside the window are dropped and the survivors shift back by `start`.
static func _crop(anim: Animation, start: float, length: float) -> void:
	var end: float = minf(anim.length, start + length)
	start = clampf(start, 0.0, maxf(anim.length - 0.05, 0.0))
	if end <= start:
		end = anim.length
	for t in range(anim.get_track_count()):
		var type: int = anim.track_get_type(t)
		if type != Animation.TYPE_POSITION_3D and type != Animation.TYPE_ROTATION_3D \
			and type != Animation.TYPE_SCALE_3D:
			continue
		var at_start: Variant = _sample(anim, t, type, start)
		var at_end: Variant = _sample(anim, t, type, end)
		for k in range(anim.track_get_key_count(t) - 1, -1, -1):
			var time: float = anim.track_get_key_time(t, k)
			if time <= start or time >= end:
				anim.track_remove_key(t, k)
			else:
				anim.track_set_key_time(t, k, time - start)
		_insert(anim, t, type, 0.0, at_start)
		_insert(anim, t, type, end - start, at_end)
	anim.length = end - start


static func _sample(anim: Animation, track: int, type: int, time: float) -> Variant:
	match type:
		Animation.TYPE_POSITION_3D:
			return anim.position_track_interpolate(track, time)
		Animation.TYPE_ROTATION_3D:
			return anim.rotation_track_interpolate(track, time)
		_:
			return anim.scale_track_interpolate(track, time)


static func _insert(anim: Animation, track: int, type: int, time: float, value: Variant) -> void:
	match type:
		Animation.TYPE_POSITION_3D:
			anim.position_track_insert_key(track, time, value)
		Animation.TYPE_ROTATION_3D:
			anim.rotation_track_insert_key(track, time, value)
		_:
			anim.scale_track_insert_key(track, time, value)


static func _find_ap(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r: AnimationPlayer = _find_ap(c)
		if r != null:
			return r
	return null
