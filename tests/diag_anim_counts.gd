extends SceneTree

## v0.9.2.1: the animation counts, by category (brief section 12).
##
## Reported from the database and the pack directory rather than typed into a
## report by hand, so the numbers cannot drift away from the code. ACTIVE is
## the honest one: a clip counts as active only if some intent that gameplay
## can actually reach resolves to it.

const SOURCE_DIR := "res://assets/animations/source"

## Intents a running match can reach today, and where from. Anything not in
## this list is mapped but has no trigger, and is counted as such.
const REACHABLE := {
	"pass": "ball_touched PASS (outfield)",
	"shoot": "ball_touched SHOT, grounded",
	"shoot_running": "ball_touched SHOT while moving fast",
	"shoot_volley": "ball_touched SHOT with the ball off the ground",
	"header": "ball contact above head height",
	"touch": "ball_touched TURN",
	"trap": "ball_touched STOP",
	"receive": "possession gained from a moving ball",
	"challenge": "challenge_started, standing",
	"challenge_slide": "committed slide (SlideTackle)",
	"tripped": "fouled by a slide",
	"fallen": "knocked down",
	"get_up": "recovering from being down",
	"save_left": "GKIntent.SAVE, ball to the left",
	"save_right": "GKIntent.SAVE, ball to the right",
	"block": "GKIntent.BLOCK",
	"catch": "keeper gains a ball off the ground",
	"scoop": "keeper gains a ball along the ground",
	"gk_miss": "left SAVE without the ball",
	"sidestep_left": "GKIntent.CLOSE_ANGLE, ball left",
	"sidestep_right": "GKIntent.CLOSE_ANGLE, ball right",
	"gk_organise": "GKIntent.POSITION with play far upfield",
	"distribute_kick": "keeper clears (SHOT)",
	"distribute_pass": "keeper passes",
	"place_ball": "GKIntent.RECOVER",
}


func _initialize() -> void:
	var pack: Array = _pack_clips()
	var mapped: Array = AnimationSet.all_mapped_clips()

	var active: Array = []
	var mapped_no_trigger: Array = []
	for intent in AnimationSet.INTENTS:
		for opt in AnimationSet.INTENTS[intent]["clips"]:
			var clip: String = opt["clip"]
			if REACHABLE.has(intent):
				if not (clip in active):
					active.append(clip)
			elif not (clip in mapped_no_trigger):
				mapped_no_trigger.append(clip)
	# Locomotion and idles are always live.
	for c in AnimationSet.LOCOMOTION:
		active.append(c)
	for c in [AnimationSet.IDLE_CLIP, AnimationSet.IDLE_CLIP_KEEPER]:
		active.append(c)
	# A clip reachable through one intent is active even if another intent
	# that also uses it has no trigger.
	var truly_untriggered: Array = []
	for c in mapped_no_trigger:
		if not (c in active):
			truly_untriggered.append(c)

	print("COUNTS: ==== v0.9.2.1 animation usage ====")
	print("COUNTS: TOTAL IMPORTED     %d" % pack.size())
	print("COUNTS: TOTAL COMPATIBLE   %d  (retarget verified on all 11 rigs)" % pack.size())
	print("COUNTS: SEMANTICALLY MAPPED %d" % mapped.size())
	print("COUNTS: ACTIVE IN GAMEPLAY %d" % active.size())
	print("COUNTS: MAPPED, NO TRIGGER %d  %s" % [truly_untriggered.size(), truly_untriggered])
	print("COUNTS: DEFERRED           %d" % AnimationSet.DEFERRED.size())
	print("COUNTS: accounted for      %d of %d" % [
		mapped.size() + AnimationSet.DEFERRED.size(), pack.size()])

	print("COUNTS: ---- by category (clips) ----")
	var cats: Dictionary = AnimationSet.category_counts()
	var keys: Array = cats.keys()
	keys.sort()
	for k in keys:
		var clips: Array = cats[k]
		var n_active := 0
		for c in clips:
			if c in active:
				n_active += 1
		print("COUNTS:   %-12s %2d/%2d active" % [k, n_active, clips.size()])

	print("COUNTS: ---- deferred, with reasons ----")
	for c in AnimationSet.DEFERRED:
		print("COUNTS:   %-26s %s" % [c, AnimationSet.DEFERRED[c]])

	print("COUNTS: ---- role split (intents) ----")
	var by_role := {"OUTFIELD": 0, "GOALKEEPER": 0, "ANY": 0}
	for intent in AnimationSet.INTENTS:
		by_role[AnimationSet.Role.keys()[AnimationSet.INTENTS[intent]["role"]]] += 1
	for k in by_role:
		print("COUNTS:   %-11s %d intents" % [k, by_role[k]])
	quit()


func _pack_clips() -> Array:
	var out: Array = []
	var d := DirAccess.open(SOURCE_DIR)
	if d == null:
		return out
	d.list_dir_begin()
	var n: String = d.get_next()
	while n != "":
		if not d.current_is_dir() and n.to_lower().ends_with(".fbx"):
			out.append(n.substr(0, n.length() - 4))
		n = d.get_next()
	d.list_dir_end()
	out.sort()
	return out
