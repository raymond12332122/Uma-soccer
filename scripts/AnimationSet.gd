class_name AnimationSet
extends RefCounted

## v0.9.2: the curated map from GAMEPLAY INTENT to a clip in the pack
## (brief sections 1, 4, 9, 10).
##
## The brief is explicit that all 54 clips must not simply be assigned. This
## is the classification step: every clip in the pack appears exactly once
## below -- under a semantic role it fills, or under UNUSED with the reason.
## Nothing here names a clip at a call site; FootballPlayer asks for
## "pass" or "sprint" and this table decides what that looks like.
##
## Every number in the tables is MEASURED, by tests/diag_anim_inventory.gd,
## on the retargeted clip. Re-running that tool reproduces them. They are not
## read off filenames, because filenames were wrong about several of them --
## the two clips called 'jog forward diagonal' turned out to be the left and
## right diagonals, distinguishable only by measuring which way the hips go.

# ---------------------------------------------------------------------------
# Locomotion
# ---------------------------------------------------------------------------

## Direction points for the locomotion blend space, in (right, forward) units.
## The angles were measured relative to 'jog forward' and matched the
## filenames' own left/right labelling, which is why the labels are trusted
## here: 'jog strafe right' measured +89.8 degrees, 'jog strafe left' -90.0.
##
##   clip                        angle    travel   duration   natural speed
##   jog forward                   0.0     2.15m     0.82s      2.62 m/s
##   jog forward diagonal        +45.0     2.31m     0.78s      2.95 m/s
##   jog forward diagonal (2)    -45.4     2.27m     0.83s      2.73 m/s
##   jog strafe right            +89.8     1.76m     0.72s      2.45 m/s
##   jog strafe left             -90.0     2.11m     0.70m      3.01 m/s
##   jog backward diagonal      +134.5     1.68m     0.72s      2.35 m/s
##   jog backward diagonal (2)  -135.5     2.13m     0.82s      2.61 m/s
##   jog backward               +-180.0    1.90m     0.78s      2.43 m/s
##
## Note the spread: 2.35 to 3.01 m/s across directions. One playback rate is
## used for the whole blend space (see NATURAL_SPEED), so a player running
## sideways slides slightly more than one running straight. That is a real,
## measured 13% residual, not a claim of perfection.
const LOCOMOTION := {
	"jog forward": Vector2(0.0, 1.0),
	"jog forward diagonal": Vector2(0.707, 0.707),
	"jog forward diagonal (2)": Vector2(-0.707, 0.707),
	"jog strafe right": Vector2(1.0, 0.0),
	"jog strafe left": Vector2(-1.0, 0.0),
	"jog backward diagonal": Vector2(0.707, -0.707),
	"jog backward diagonal (2)": Vector2(-0.707, -0.707),
	"jog backward": Vector2(0.0, -1.0),
}

## The clip the character stands in when not moving. 'offensive idle' is the
## outfield one (10.55s, no travel); goalkeepers get their own below.
const IDLE_CLIP := "offensive idle"
const IDLE_CLIP_KEEPER := "goalkeeper idle"

## Mean ground speed of the eight locomotion clips ON THE PACK SKELETON.
##
## This is the pack-space figure and is NOT what the game divides by: the
## rendered characters are retargeted and then scaled to a 1.6m target height,
## so their real stride differs. AnimationController measures the rendered
## figure per character at spawn (see _measure_natural_speed) and uses that.
## Kept here as the reference the measurement is sanity-checked against.
const PACK_NATURAL_SPEED := 2.64

## Ground speed a locomotion clip covers on a RENDERED character at 1x rate,
## after retargeting and after the 1.6m height normalisation, MEASURED per
## character by tests/diag_foot_slide.gd.
##
## Per character rather than one number because the roster's rigs differ by
## 19% here (2.87 m/s on Tamamo Cross to 3.49 on Gold Ship): they are
## normalised to the same total height, but leg length as a fraction of that
## height is not the same, and the stride follows the legs. Using the mean for
## everyone would leave the extremes sliding by a tenth of their own speed for
## no reason, when the fix is a lookup.
##
## Note also how far this is from the pack's own 2.64 m/s: driving the rate
## off PACK_NATURAL_SPEED would have every player's feet running 22% slow.
const RENDERED_NATURAL_SPEED_BY_VISUAL := {
	"agnes_digital": 2.93,
	"air_groove": 3.38,
	"gold_ship": 3.49,
	"grass_wonder": 3.12,
	"mejiro_mcqueen": 3.26,
	"oguri_cap": 3.42,
	"silence_suzuka": 3.30,
	"symboli_rudolf": 3.38,
	"tamamo_cross": 2.87,
	"tm_opera_o": 3.20,
	"tokai_teio": 3.08,
}

## Roster mean, used for a visual with no measured entry.
const RENDERED_NATURAL_SPEED := 3.22


static func natural_speed(visual_id: String) -> float:
	return RENDERED_NATURAL_SPEED_BY_VISUAL.get(visual_id, RENDERED_NATURAL_SPEED)

## Yaw correction applied to every character model, in degrees (section 18).
##
## ONE place, not a per-character export, because the correction is a property
## of the pack-plus-rig combination and is identical for all 11: they share a
## rest pose and now share bone names too.
##
## MEASURED as zero by tests/diag_foot_slide.gd, which reads the direction the
## retargeted rest pose faces off the shoulder line, for the pack and for
## every character. All twelve report the same thing: they face the model's
## local +Z, which is already this game's forward. Retargeting did not rotate
## anything, and no correction is needed -- but that is now a measurement
## rather than the assumption it was before this milestone.
const MODEL_YAW_OFFSET_DEGREES := 0.0

## The character's own RIGHT, in the model's local frame.
##
## Not +X. Godot is right-handed with a node's forward at -Z, while this
## project's convention is that a player faces +Z, so the model's local axes
## run opposite to the usual reading: with forward at +Z and up at +Y,
## right = forward x up = -X.
##
## This matters because the strafe clips are authored for a real anatomical
## side. Feeding the blend space +X would play the strafe-LEFT clip whenever
## a player moved right -- legs crossing the wrong way, permanently, on every
## sideways step. Confirmed by measurement rather than by this argument:
## diag_foot_slide reports 'jog strafe right' travelling at right +0.96 in a
## frame built from the rest pose's own shoulder line.
const MODEL_RIGHT := Vector3(-1.0, 0.0, 0.0)

## Playback rate is clamped to this band. Outside it a jog clip stops reading
## as a person running: below ~0.55 the legs crawl while the body slides, and
## above ~1.9 it turns into a sewing machine. The game's sprint speed (8.5
## m/s) is roughly 3x the clip's natural speed, so the top of this band IS
## reached and sprinting does slide. That is the honest consequence of a pack
## with one gait in it, and it is measured and reported rather than papered
## over by pretending the clip is a sprint.
const RATE_MIN := 0.55
const RATE_MAX := 1.90

## Below this ground speed the character is treated as standing.
const IDLE_SPEED := 0.30
## Ground speed at which the locomotion blend is fully in (linear below).
const FULL_MOVE_SPEED := 1.60

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

## Gameplay intent -> how to play a clip for it.
##
##   clip      which file in the pack
##   start     where playback begins, in clip seconds. WIND_UP means "from the
##             clip's own start"; otherwise it is the measured contact time,
##             so the boot is driving through the ball on frame one.
##   tail      how much is kept after `start`; the rest is cropped away so an
##             action cannot lock the body for seconds
##   fade_in / fade_out   cross-fade against the locomotion underneath
##
## WHY MOST STRIKES START AT CONTACT, which is the crux of sections 9 and 10:
## gameplay decides to pass and launches the ball on the same frame.
## FootballPlayer's own event documentation says so -- action_started "fires
## on the same frame as the contact today (the simulation has no wind-up)".
## There is no telegraph to hide a wind-up behind, and delaying the ball to
## wait for the animation would make the animation authoritative over
## gameplay, which the brief forbids. So a strike starts AT its contact
## frame: the boot is at peak speed on the frame the ball leaves, and what
## plays is the follow-through. The cost is a fast blend into mid-swing
## instead of a visible wind-up. That is a cost, not a solved problem.
##
## The exceptions are the intents where gameplay DOES give warning: the
## challenge clips fire from challenge_started, which v0.9.1 added precisely
## because "a foot does not arrive at the ball on the frame it is asked to",
## and throw-ins and getting up are not reactions to anything.
##
## CLIP CHOICE IS DRIVEN BY HOW MUCH FOLLOW-THROUGH EXISTS. Measured
## (duration - contact) for every strike-shaped clip in the pack:
##   soccer penalty kick   0.76s     scissor kick          2.00s
##   header soccerball     1.46s     header soccerball (2) 4.00s
##   kneeing soccerball(2) 0.51s     stall soccerball (4)  0.42s
##   kick soccerball       0.06s     kick soccerball (2)   0.09s
##   kick up soccerball    0.10s     kneeing soccerball    0.14s
## The bottom row is why the two clips actually named 'kick soccerball' are
## NOT the pass and shot animations: three or five frames remain after the
## boot meets the ball, which is not a kick anybody can see.
const WIND_UP := -1.0

const ACTIONS := {
	"pass": {"clip": "soccer penalty kick", "start": 0.74, "tail": 0.55, "fade_in": 0.07, "fade_out": 0.18},
	"shoot": {"clip": "soccer penalty kick", "start": 0.74, "tail": 0.76, "fade_in": 0.07, "fade_out": 0.25},
	"shoot_volley": {"clip": "scissor kick", "start": 0.75, "tail": 1.00, "fade_in": 0.10, "fade_out": 0.30},
	"header": {"clip": "header soccerball", "start": 0.42, "tail": 0.90, "fade_in": 0.08, "fade_out": 0.25},
	"header_high": {"clip": "header soccerball (2)", "start": 0.18, "tail": 1.10, "fade_in": 0.08, "fade_out": 0.25},
	"touch": {"clip": "kneeing soccerball (2)", "start": 0.12, "tail": 0.45, "fade_in": 0.06, "fade_out": 0.14},
	"trap": {"clip": "stall soccerball (4)", "start": 1.40, "tail": 0.42, "fade_in": 0.10, "fade_out": 0.20},
	"trap_alt": {"clip": "stall soccerball", "start": 2.85, "tail": 0.40, "fade_in": 0.10, "fade_out": 0.20},
	"receive": {"clip": "receive soccerball", "start": 0.55, "tail": 0.90, "fade_in": 0.10, "fade_out": 0.20},
	"challenge": {"clip": "soccer tackle (3)", "start": WIND_UP, "tail": 1.20, "fade_in": 0.10, "fade_out": 0.25},
	"challenge_slide": {"clip": "soccer tackle (2)", "start": WIND_UP, "tail": 1.40, "fade_in": 0.10, "fade_out": 0.30},
	"tripped": {"clip": "soccer trip", "start": WIND_UP, "tail": 1.60, "fade_in": 0.06, "fade_out": 0.30},
	"throw_in": {"clip": "throw in", "start": WIND_UP, "tail": 2.77, "fade_in": 0.15, "fade_out": 0.25},
	"get_up": {"clip": "standing up", "start": WIND_UP, "tail": 1.65, "fade_in": 0.10, "fade_out": 0.25},
}

## Goalkeeper intent (AIController.GKIntent) -> clip. Purely a visual mapping;
## no keeper decision changes in this milestone (brief section 26 keeps the
## v0.9.1.1 threat model exactly as it is).
##
## The keeper's dive and block clips start from their own beginning: a keeper
## commits to a save from GK_SAVE_TIME (1.1s) of warning, which is the one
## place in the game where a wind-up genuinely has room to play. The
## distribution clips start at contact for the same reason outfield strikes
## do -- the ball leaves on the decision frame.
const KEEPER_ACTIONS := {
	"save_left": {"clip": "goalkeeper diving save", "start": WIND_UP, "tail": 1.60, "fade_in": 0.06, "fade_out": 0.30},
	"save_right": {"clip": "goalkeeper diving save (2)", "start": WIND_UP, "tail": 1.60, "fade_in": 0.06, "fade_out": 0.30},
	"block": {"clip": "goalkeeper body block", "start": WIND_UP, "tail": 1.30, "fade_in": 0.08, "fade_out": 0.25},
	"block_low": {"clip": "goalkeeper body block (2)", "start": WIND_UP, "tail": 1.20, "fade_in": 0.08, "fade_out": 0.25},
	"block_high": {"clip": "goalkeeper body block (3)", "start": WIND_UP, "tail": 1.60, "fade_in": 0.08, "fade_out": 0.25},
	"catch": {"clip": "goalkeeper catch", "start": WIND_UP, "tail": 1.40, "fade_in": 0.08, "fade_out": 0.25},
	"catch_high": {"clip": "goalkeeper catch (2)", "start": WIND_UP, "tail": 1.25, "fade_in": 0.08, "fade_out": 0.25},
	"scoop": {"clip": "goalkeeper scoop", "start": WIND_UP, "tail": 1.40, "fade_in": 0.10, "fade_out": 0.25},
	"miss": {"clip": "goalkeeper miss", "start": WIND_UP, "tail": 1.40, "fade_in": 0.08, "fade_out": 0.30},
	"sidestep_left": {"clip": "goalkeeper sidestep", "start": WIND_UP, "tail": 0.52, "fade_in": 0.06, "fade_out": 0.12},
	"sidestep_right": {"clip": "goalkeeper sidestep (2)", "start": WIND_UP, "tail": 0.50, "fade_in": 0.06, "fade_out": 0.12},
	"distribute_kick": {"clip": "goalkeeper drop kick", "start": 2.09, "tail": 1.00, "fade_in": 0.08, "fade_out": 0.25},
	"distribute_throw": {"clip": "goalkeeper overhand throw", "start": 1.79, "tail": 1.00, "fade_in": 0.08, "fade_out": 0.25},
	"distribute_pass": {"clip": "goalkeeper pass", "start": 0.64, "tail": 0.80, "fade_in": 0.08, "fade_out": 0.25},
	"place_ball": {"clip": "goalkeeper placing ball", "start": WIND_UP, "tail": 2.00, "fade_in": 0.12, "fade_out": 0.25},
}

## Reactions, kept from the pre-animation controller's vocabulary so the
## existing FootballPlayer call sites keep working. Only the ones the pack can
## actually serve are listed; the rest fall through to procedural motion.
const REACTIONS := {
	"tackle": "challenge",
	"pass": "pass",
	"shoot": "shoot",
}

## Clips deliberately not wired to anything, with the reason. Listed so the
## report's ACTIVE count can be checked against the pack and so a later
## milestone can pick them up knowingly rather than rediscovering them.
##
## The three 'kick' clips are the notable ones: they are the obvious names to
## reach for and they are the wrong choice, because 0.06s, 0.09s and 0.10s
## respectively remain after the boot meets the ball, and the follow-through
## is the only part gameplay leaves room to show.
const UNUSED := {
	"kick soccerball": "0.06s remains after contact; nothing visible to play",
	"kick soccerball (2)": "0.09s remains after contact; nothing visible to play",
	"kick up soccerball": "0.10s remains after contact; nothing visible to play",
	"kneeing soccerball": "0.14s after contact; the (2) variant gives 0.51s",
	"stall soccerball (2)": "third stall variant, two are mapped",
	"stall soccerball (3)": "fourth stall variant, two are mapped",
	"soccer tackle": "third tackle variant, two are mapped",
	"fallen idle": "needs a knocked-down state that does not exist",
	"transition": "unidentifiable 0.77s clip, no measurable foot event",
	"strike foward jog": "run-up baked in: would move the player 3.12m itself",
	"goalkeeper catch (3)": "near-duplicate of goalkeeper catch",
	"goalkeeper catch (4)": "near-duplicate of goalkeeper catch",
	"goalkeeper directing": "7.2s of pointing; no gameplay state means this",
	"goalkeeper directing (2)": "7.7s of pointing; no gameplay state means this",
	"goalkeeper idle (2)": "alternate idle, no selector for it yet",
	"goalkeeper placing ball (2)": "8.0s variant of a 3.5s clip already mapped",
}


## Every clip name this table refers to, for the build step and for the
## report's counts.
static func all_mapped_clips() -> Array:
	var out: Array = []
	for c in LOCOMOTION:
		out.append(c)
	out.append(IDLE_CLIP)
	out.append(IDLE_CLIP_KEEPER)
	for k in ACTIONS:
		var c: String = ACTIONS[k]["clip"]
		if not (c in out):
			out.append(c)
	for k in KEEPER_ACTIONS:
		var c: String = KEEPER_ACTIONS[k]["clip"]
		if not (c in out):
			out.append(c)
	return out


## Look up an action entry by intent, across both tables.
static func action(intent: String) -> Dictionary:
	if ACTIONS.has(intent):
		return ACTIONS[intent]
	if KEEPER_ACTIONS.has(intent):
		return KEEPER_ACTIONS[intent]
	return {}
