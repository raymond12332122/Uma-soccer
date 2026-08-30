class_name FootballPlayer
extends CharacterBody3D

## Reusable entity for every player on the pitch -- human-controlled,
## AI-controlled, or goalkeeper. This script owns movement/dribbling/
## kicking simulation only. It never reads Input or InputState directly;
## exactly one driver (PlayerController for the human, or TeamController/
## AIController for everyone else) writes into the intent fields below
## each physics frame, and this script simulates the result.

## ---- Ball-contact events (v0.9.0) ----
##
## Every deliberate contact this player makes with the ball is announced
## here, with enough context to drive an animation from it later.
##
## The dependency runs ONE WAY on purpose: the physics emits, and anything
## that cares subscribes. Nothing in the simulation reads this signal or
## waits for a listener, so close control works identically with no
## animation system attached -- which is the milestone's requirement that
## the physics stand on its own. When the animation pack does arrive it can
## either listen here (ball drives the animation) or, for a foot-planted
## contact, call the same _apply_* entry points from an animation key frame
## (animation drives the ball) without either side being rewritten.
##
## `info` is a Dictionary so listeners can ignore fields they do not use and
## new fields can be added without breaking them:
##   kind            -- TouchKind, what sort of contact this was
##   point           -- world position of the contact (ball side, at foot
##                      height), the anchor an IK/foot-plant would target
##   direction       -- unit Vector3 the ball was sent in
##   strength        -- delta-v applied to the ball, m/s
##   distance        -- how far ahead the touch is intended to put the ball
##   player_velocity -- carrier's velocity at contact, for stride matching
##   foot            -- "left"/"right", chosen from which side the ball sat
signal ball_touched(info: Dictionary)

## v0.9.1: the rest of the animation-facing event surface.
##
## `ball_touched` covers the instant of CONTACT, which is the frame an
## animation has to be ALREADY in -- a foot does not arrive at the ball on the
## frame it is asked to. These four cover the moments before and after, so a
## clip can be started with lead time and blended out on completion:
##
##   action_started    -- intent committed; the wind-up may begin. Fires on
##                        the same frame as the contact today (the simulation
##                        has no wind-up), so a listener that needs anticipation
##                        should start its clip here and let ball_touched drive
##                        the plant.
##   action_released   -- the ball is gone and the follow-through owns the body
##   challenge_started -- a defender has begun building challenge progress
##                        against a carrier; the tackle animation starts here
##                        and the outcome is not known yet
##   possession_changed -- gained/lost, for a settle/react clip
##
## Same one-way rule as ball_touched: the simulation emits and never reads.
##
## `info` fields, all optional to a listener:
##   kind      -- TouchKind for the action signals; "gained"/"lost" for
##                possession_changed
##   direction -- unit Vector3 the ball was/will be sent in
##   strength  -- launch speed in m/s (0 where not applicable)
##   target    -- the intended receiver for a pass, else null
##   position  -- the player's world position at the event
signal action_started(info: Dictionary)
signal action_released(info: Dictionary)
signal challenge_started(info: Dictionary)
signal possession_changed(info: Dictionary)

## v0.9.1: the full decision trace for one pass, emitted by execute_pass().
##
## Diagnostic and test surface only -- nothing in the simulation reads it.
## The brief asks for the whole chain to be visible in one record rather than
## re-derived from separate log lines, so every stage a pass goes through is
## here: what the human aimed, who was considered and why each was kept or
## dropped, what was chosen, the geometry of the error between intent and
## outcome, and the launch velocity actually applied to the ball.
##
##   aim              -- the raw aim vector (human stick / AI facing)
##   aimed            -- true for a human-aimed pass (hard cone applied)
##   candidates       -- Array of per-teammate Dictionaries, see
##                       PassEvaluator.best_option's `trace`
##   considered       -- how many teammates survived every filter
##   target           -- the chosen receiver (null = no-target knock)
##   target_name      -- its name, for log lines
##   kind             -- PassEvaluator.PassKind of the chosen option
##   score            -- the chosen option's score
##   distance         -- passer-to-receiver distance, m
##   aim_point        -- where the ball was actually aimed (includes lead)
##   angular_error    -- degrees between the raw aim and the kick direction;
##                       this is the assist, and it must stay small
##   kick_direction   -- the unit direction the impulse was applied along
##   requested_speed  -- the launch speed the model asked for, m/s
##   actual_speed     -- the ball's speed on the frame after the impulse.
##                       Necessarily NOT known at emit time: the signal fires
##                       just before the impulse so the requested speed is
##                       still the live one, and this field is written into
##                       the same Dictionary one physics frame later. A
##                       listener that keeps the Dictionary sees it appear; a
##                       listener that copies the value out immediately reads
##                       zero.
signal pass_attempted(info: Dictionary)

## What kind of contact a `ball_touched` event describes.
enum TouchKind {
	DRIBBLE,    ## ordinary knock-on in the direction of travel
	TURN,       ## first contact of a direction change; kills old momentum
	STOP,       ## foot on the ball to settle it while slowing to a halt
	PASS,       ## deliberate pass
	SHOT,       ## deliberate shot
}

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

## This player's own side's tactical plan, wired once by MatchManager. Read
## only by execute_pass(), so a HUMAN pass is evaluated with the same team
## context an AI pass gets -- the forward axis in particular, without which
## the largest term in PassEvaluator's scoring silently contributed nothing
## to every pass the player made. Never mutated here.
var team_plan: TeamPlan = null

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
#
# v0.8.6: the leash is longer and the spring softer. v0.8.2-v0.8.5 fixed
# the ball ESCAPING (the heavy-touch cutout, the snapping facing angle);
# what was left was the opposite complaint -- the ball being rigid, "hard
# to interact with", not really a separate object from the player. That is
# a straightforward consequence of holding it 0.62m ahead with a spring
# stiff enough (accel 16-30, clamped at 18 m/s^2) to saturate at well under
# a metre of error: within its own radius the ball simply cannot lag, lead,
# or be knocked off line, so there is nothing to feel.
#
# Deliberately NOT done here, per the brief: the player capsule and the
# ControlArea radius are untouched, and the ball remains a fully simulated
# RigidBody3D that is only ever nudged -- never parented, never dragged.
# A longer leash also makes the ball marginally EASIER to take (BallContest
# scores a challenger on their distance to the BALL, not to the carrier),
# which is the right direction and does not regress stealing.
#
# v0.8.7: THE LEASH WAS SHORTER THAN THE PLAYER'S OWN BODY. This is the
# root cause of "dribbling feels like PUSH BALL -> CHASE BALL -> PUSH BALL"
# and of the ball feeling heavy and stuck, and it is geometry, not tuning:
#
#   player capsule radius 0.40 + old ball radius 0.35 = 0.75m
#
# is the closest the two bodies' CENTRES can ever be. The walking leash
# asked for 0.62m and the sprint leash for 1.05m, so at walking pace the
# spring was pulling the ball to a point 0.13m INSIDE the player's own
# collision capsule -- a place it is physically impossible for the ball to
# occupy. The ball therefore never sat "in front of" the dribbler at all;
# it was permanently jammed against the capsule and shoved along by it,
# which is precisely why it read as an object welded to the player, and why
# the player is a physical obstacle to their own ball.
#
# Measured before the fix (diag_v087, 120-frame runs, everyone else parked):
#   sprinting: ball 0.86m away (i.e. AT the 0.75 contact floor), and the
#              carrier could only reach 1.5 m/s -- they were shoving the
#              ball with their body the whole way.
#   walking:   the ball is knocked away instead and possession survives
#              only 31 of 120 frames while the player runs on at 5.6 m/s.
# There was no regime in which a human moved at pace AND kept the ball.
#
# The ball is now 0.16m radius (see Ball.tscn -- it was also ~3x oversized
# visually: 0.70m across against a 1.6m player), putting the contact floor
# at 0.56m, and BOTH leashes now sit clearly outside it. The ball has real
# separation from the body at last, which is what makes it a thing you
# touch rather than a thing you carry.
@export var dribble_distance: float = 0.85
@export var dribble_distance_sprint: float = 1.35
var dribble_accel: float = 13.0
@export var dribble_damping_accel: float = 6.0
@export var dribble_force_accel_clamp: float = 18.0
var control_loss_angle_threshold: float = 1.2
@export var control_loss_speed_threshold: float = 2.5
@export var control_loss_duration: float = 0.35

# ---- v0.8.7: touch-based close control ----
# The brief asks for "actual touch-based close control, NOT permanent ball
# attachment", and for a change of direction to be something the ball
# follows through a touch rather than something it is dragged through.
#
# The old model applied a spring force toward a point ahead of the player
# EVERY FRAME, along every axis. That is permanent attachment by
# definition: the ball had no independent motion left to feel, because any
# deviation was corrected within a frame or two by a force stiff enough to
# saturate its own clamp.
#
# The model here splits the two things a dribbler actually does:
#
#   1. TOUCHES  -- discrete impulses that knock the ball ahead. This is the
#      only thing that drives the ball ALONG its direction of travel. Between
#      touches the ball simply rolls, decelerating under its own friction and
#      damping, and the player runs after it. That gap is the dribble.
#   2. SHEPHERDING -- a gentle force applied ONLY perpendicular to the
#      direction of travel, so the ball stays in the player's corridor
#      instead of drifting off sideways. It cannot pull the ball forward or
#      hold it back, so it can never re-create the welded feel.
#
# A direction change re-touches the ball early (subject to a shorter
# minimum interval), which is what makes a simple fake work: run left, flick
# the stick right, and the next touch sends the ball right.
## Shortest gap between touches at a walk, and at a sprint. Touching more
## often at pace is what keeps a fast dribble from running away.
const TOUCH_INTERVAL_WALK := 0.42
const TOUCH_INTERVAL_SPRINT := 0.26
## A direction change may re-touch sooner than that -- otherwise a fake is
## only as responsive as whatever remains of the current interval.
## v0.9.0: TRIED 0.20 AND REVERTED. Raising this floor (8 touches/s -> 5)
## looked like the cure for a turn that reads as pushing, and it costs
## possession outright: through a 90-degree turn at pace the carrier held
## the ball for 42 of 120 frames at 0.20 against 120 of 120 at 0.12. A
## rolling ball needs several capped impulses to redirect, and this is what
## pays for them. The dragging feel is the lateral shepherd force, not the
## touch rate -- see SHEPHERD_ACCEL.
const TOUCH_INTERVAL_TURN := 0.12

## v0.9.0: the turn interval applies to the FIRST touch of a turn, not to
## every touch for as long as the turn lasts.
##
## `turning` compares the dribble direction against the direction the ball
## is actually rolling, and one touch does not fully redirect a rolling
## ball -- so through a sustained turn the condition stayed true, re-armed
## the 0.12s floor on every touch, and the dribble collapsed into a push.
## Measured in the isolated close-control scene: a 90-degree turn produced
## 8.0 touches per second against 2.7 running straight, with the gap pinned
## at the floor for the whole manoeuvre. That is the "dragging" the human
## playtest reported -- it appears exactly when the player is steering,
## which is when they are paying attention.
##
## After this many seconds of continuously turning, touch spacing returns to
## the ordinary pace-based interval: a turn gets its sharp first contact and
## then settles into a normal rhythm on the new line.
const TURN_BURST_DURATION := 0.22

## ---- Stopping with the ball (v0.9.0) ----
## A carrier who releases the stick still has to DO something about a ball
## that is rolling away -- see the `stopping` block in _update_possession.
## Below this ball speed there is nothing to kill; the settle damper handles
## the rest.
const STOP_TOUCH_MIN_BALL_SPEED := 0.9
## Only a player who has actually slowed down is "stopping". Above this they
## are still running, and the ordinary dribble touch applies.
const STOP_TOUCH_MAX_PLAYER_SPEED := 2.2
## How quickly the ball is brought back toward the feet. Deliberately gentle
## -- this is a foot placed on the ball, not a backwards pass.
const STOP_TOUCH_RETURN_SPEED := 1.6
## Spacing for stopping touches; a little slower than a dribble touch,
## because settling a ball is one deliberate contact rather than a rhythm.
const STOP_TOUCH_INTERVAL := 0.30
## Re-touch once the ball has come closer than this fraction of the leash.
const TOUCH_TRIGGER_RATIO := 0.72
## How much the desired direction must differ from where the ball is
## actually travelling before it counts as a turn (radians, ~30 degrees).
const TOUCH_TURN_ANGLE := 0.52
## The ball leaves a touch slightly faster than the player so that, after
## friction has eaten into it over the interval, it is still ahead of them.
const TOUCH_SPEED_MATCH := 1.14
## Floor so a stationary player can still stroke the ball around.
const TOUCH_MIN_SPEED := 1.1
## How much faster than the player a touch may send the ball. Small on
## purpose: this is the speed at which the ball pulls AHEAD, and the player
## has to be able to run onto it again.
const TOUCH_MAX_CLOSING := 1.8
## How far the ball's speed may fall below the player's before the next
## touch is treated as urgent -- see the `trailing` case.
const TOUCH_TRAIL_SPEED_GAP := 1.5
## Hard ceiling on how much velocity ONE touch may add. A touch is a
## controlled contact, never a pass -- this is what keeps close control
## clearly distinct from PASS_SPEED_MIN (4.0).
const TOUCH_MAX_DELTA_V := 3.4
## Allowance for a touch that CHANGES DIRECTION -- see the turn handling in
## _update_possession. Still comfortably under PASS_SPEED_MIN (4.0) in
## terms of the speed it can leave on the ball travelling forward, because
## most of it is spent cancelling the old direction.
const TOUCH_MAX_DELTA_V_TURN := 7.5
## Sideways-only shepherding gains. Deliberately far softer than the old
## spring (16-30 accel) because it is no longer holding the ball ahead --
## that job belongs to the touches.
const SHEPHERD_ACCEL := 7.0
const SHEPHERD_DAMPING := 3.2
## Ceiling on the shepherding force, well under a touch.
const SHEPHERD_ACCEL_CLAMP := 9.0

## Damping applied to a ball at the feet of a carrier who is not currently
## going anywhere. Damping-only by design: it can slow the ball but never
## move it, so a resting ball beside a standing player stays put.
const SETTLE_DAMPING := 6.0
const SETTLE_ACCEL_CLAMP := 10.0
## How much wider than the sprint leash the close-control sensor must be.
## A carrier has to be able to knock the ball its full dribble distance
## ahead and still be holding it -- see apply_player_data().
## Kept as tight as the leash allows: this radius is also what decides who
## counts as the carrier, so an over-large bubble makes possession sticky
## for whoever is merely nearest the ball rather than genuinely on it.
const CONTROL_RADIUS_LEASH_MARGIN := 1.15

## Fraction of normal dribble steering that survives a heavy touch. Not
## zero -- see _update_possession.
const CONTROL_LOSS_STEER_SCALE := 0.3
## Ceiling on how much speed a single frame's shove can add to the ball --
## see _push_ball_on_contact(). A nudge that resolves over a few frames,
## which is also what a foot does to a ball.
const BALL_PUSH_MAX_DELTA_V := 2.5
## How long a player stays committed to the play they just made. Long
## enough to follow a shot in for the rebound or continue a run after
## laying the ball off; short enough that it is a follow-up, not a refusal
## to defend.
const POST_ACTION_WINDOW := 2.5
@export var possession_release_cooldown: float = 0.35
## How long has_possession survives the ball leaving the control radius
## when it was NOT deliberately kicked away -- see _update_possession.
## Short enough that a real dispossession still registers promptly.
const POSSESSION_GRACE := 0.15
## How close the ball must be to GAIN possession, as opposed to keeping it.
## Keeping it still works out to the full ControlArea; see _update_possession.
##
## Sized by sweeping it against how much of a match the ball is actually
## under someone's control, rather than picked for feel. At 0.95m -- barely
## more than the two collision shapes touching (0.40 capsule + 0.16 ball) --
## nobody could collect a LOOSE ball either, and the ball ran ownerless for
## 83% of a match, which is not football. Measured ownership across a
## 25s match, two runs each: 0.95m -> 17%, 1.20m -> 35%, 1.45m -> 32%,
## 1.75m -> 46%.
##
## 1.20m is about one stride. It sits well inside BallContest's 2.4m
## challenge range, and well below the distances the pre-v0.8.8 bug was
## handing possession over at (measured 1.61m mean, 2.74m max), so the
## reported steals from unrealistic range stay impossible. 1.75m recovers
## the most possession but is essentially the old behaviour, i.e. the bug.
const POSSESSION_CONTACT_RADIUS := 1.20
## Live value, so a diagnostic can sweep it. Always the constant in play.
@export var possession_contact_radius: float = POSSESSION_CONTACT_RADIUS
## How long after winning a challenge a player may take possession from
## outside the contact radius. BallContest pokes the ball toward the winner,
## so they need a moment to actually collect it -- without this the tackle
## lands and then nobody can pick the ball up.
const CONTEST_WIN_GRACE := 0.6

## v0.9.0: how far a contest winner may reach, during that grace, to collect
## the ball they just won. The grace STRETCHES the contact radius to this;
## it no longer removes the requirement altogether. TACKLE_KNOCK_SPEED puts
## the ball roughly a stride away, so a stride is what this needs to be --
## enough to pick up what you poked, never enough to take a ball that is not
## there.
const CONTEST_WIN_REACH := 1.70

## v0.9.0: a hard ceiling on RETAIN-LOOSE. Keeping the ball works out to the
## control radius plus POSSESSION_GRACE, and that combination had no upper
## bound at all: measured in a live match, the ball reached a mean of 1.42m
## and a worst of 3.56m from a player who still counted as having it. A ball
## three and a half metres away is not "his" by any reading, and a carrier
## elected on that basis is what makes a turnover look absurd from the
## outside -- both to the player being robbed and to the one watching an
## opponent apparently take the ball from range.
##
## Sized above the control radius (~1.55-1.90m) so ordinary touch dribbling
## and the existing grace are untouched; it only cuts off the tail where
## possession had become fiction.
const RETAIN_MAX_DISTANCE := 2.20

# ---- Pass / Shoot ----
# v0.8.3: these are LAUNCH SPEEDS in m/s, not impulse magnitudes. The old
# fields were raw impulses, which made them impossible to reason about
# (they only became a speed after dividing by the ball's mass) and left the
# v0.8.2 comment below actively wrong: it claimed pass power had been
# raised to 2.8, but apply_player_data() unconditionally overwrote that
# with the v0.8.1 range of 1.4-2.6 for every player actually spawned with
# player_data -- i.e. every player in a real match. At 0.45kg that is a
# launch speed of 3.1-5.8 m/s, barely faster than a player jogging, and
# (measured: roll distance ~= 1.66 * speed - 1.4) a total carry of 3.7-8.2m
# while the pass search happily selected teammates up to 26m away. That
# single unit-level bug is the bulk of "passes are often not useful".
#
# Working in speeds also makes the shot/pass distinction checkable rather
# than a matter of opinion: the two bands below cannot overlap, and a test
# asserts it (see SHOT_SPEED_MIN vs PassEvaluator.PASS_SPEED_MAX).
const SHOT_SPEED_MIN := 12.5
const SHOT_SPEED_MAX := 17.0
## Charge floor and the distance at which a shot is struck at full power --
## see shot_charge_for_distance(). 14m is a shade over the widest personal
## shooting range any personality produces, so a shot taken at the very edge
## of a player's range is hit flat out.
const SHOT_CHARGE_MIN := 0.4
const SHOT_CHARGE_FULL_DISTANCE := 14.0
var shoot_min_speed: float = SHOT_SPEED_MIN
var shoot_max_speed: float = SHOT_SPEED_MAX
## Multiplier applied to PassEvaluator's solved launch speed -- a better
## passer strikes the ball a touch more cleanly. Deliberately small: the
## distance solve does the real work, skill only trims it.
var pass_speed_scale: float = 1.0
@export var shoot_charge_time: float = 1.1
## Vertical launch speed added to a kick, m/s (v0.8.3: was an impulse;
## 0.78 m/s reproduces the old 0.35 N.s on a 0.45kg ball exactly).
@export var kick_lift: float = 0.78
## Passes stay on the deck -- see _apply_kick_impulse. Just enough to stop
## the ball scuffing into the pitch, not enough to make it bounce.
const PASS_LIFT := 0.05

## Above this speed RELATIVE to a player, a ball is arriving rather than
## being carried, and it collides with them instead of passing through --
## see the carrier exception in _update_possession.
##
## Sits above the measured arrival speed of a pass (3.3-4.8 m/s at the
## receiver, see PassEvaluator.PASS_ARRIVAL_SPEED) so a normal pass is still
## collected cleanly, and far below the shot band (SHOT_SPEED_MIN 12.5) so a
## struck ball always has to be stopped by a body rather than absorbed by
## standing near it.
const CONTROLLED_BALL_SPEED := 6.0
@export var momentum_transfer: float = 0.25

# ---- Pass assist tunables (see _get_pass_direction / _find_pass_target) ----
const PASS_ASSIST_MAX_DISTANCE := 26.0
## cos(60deg) -- a candidate must be roughly where the player is pointing.
##
## v0.9.1: was 0.25, i.e. a 76-degree cone. Measured (diag_human_pass, the
## aim-cone sweep): with the ball at his feet and the stick held dead
## forward, a teammate 72 degrees off to the left was still selected, and
## because an aimed pass then goes 92% of the way onto the chosen man (see
## PASS_ASSIST_BLEND_AIMED) the ball left the boot 66 degrees away from where
## the player pointed. That is not assistance, it is the game overruling the
## input, and it is the concrete mechanism behind "the human PASS still does
## not feel right".
##
## The blend is deliberately NOT the lever here. Intent is expressed by which
## teammate you point at, so once one is chosen the ball should go to them
## accurately; softening the blend instead would make every pass miss by a
## proportion of its own aim error, which is worse. The cone is what decides
## whether the player pointed at that man at all, and 76 degrees is not
## pointing at anyone. Measured across the sweep at the new value: 20/40/60
## degrees off still select and are struck accurately, 72 and 80 fall through
## to an honest knock in the direction actually aimed.
const PASS_ASSIST_MIN_ALIGNMENT := 0.50
const PASS_ASSIST_BLEND := 0.7           ## 0 = pure raw aim, 1 = dead-on at the chosen teammate
## v0.8.6: how much of an AIMED human pass goes dead at the teammate the
## player picked out. Deliberately near 1: having made alignment decide WHO
## receives the ball, sending it 30% of the way back toward the raw stick
## angle just reintroduces the miss at the last step.
const PASS_ASSIST_BLEND_AIMED := 0.92
## Speed of a pass with no teammate to play to -- a knock into space, kept
## far enough below SHOT_SPEED_MIN that it can never read as a strike at
## goal. See the fallback branch in execute_pass().
const PASS_NO_TARGET_SPEED := 7.0
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
## v0.8.6: a small team-coloured ring on the grass under every player, so
## which shirts are yours is readable at a glance without memorising eleven
## character models. Deliberately the smallest thing that answers the
## question: no UI panels, no overhead arrows on twenty-two players, nothing
## that covers the pitch. The controlled player keeps their own larger
## ControlIndicator ring on top of this, so "which one am I" and "which ones
## are mine" stay two distinguishable answers.
@onready var team_ring: MeshInstance3D = $TeamRing

var ball_in_action_range: RigidBody3D = null
var ball_in_control_range: RigidBody3D = null
## Last ball either sensor reported. Kept so a distance check still works
## when the ball has rolled outside BOTH areas -- the runaway case
## RETAIN_MAX_DISTANCE exists to cut off -- and so a stale reference on the
## frame the ball is repositioned does not read as "no ball".
var _known_ball: RigidBody3D = null

var has_possession: bool = false
var _facing_angle: float = 0.0

## v0.8.3: every kick this player makes is recorded here, so "was that a
## shot or a pass?" is an observable fact rather than something a human (or
## a test) has to infer from how fast the ball happened to end up moving.
## The playtest report specifically could not distinguish AI shots from AI
## passes on screen; without a recorded intent there was no way to tell
## whether that was a presentation problem or the AI genuinely never
## shooting. Written by _apply_kick_impulse only; never read by gameplay.
enum KickKind { NONE, PASS, SHOT }
var last_kick_kind: int = KickKind.NONE
var last_kick_power: float = 0.0
var last_kick_dir: Vector3 = Vector3.ZERO
## For a pass: the teammate it was actually aimed at (null if none was
## found and it was a blind clearance). For a shot: always null.
var last_kick_target: FootballPlayer = null
## Which kind of pass the last one was -- see PassEvaluator.PassKind.
var last_pass_kind: int = PassEvaluator.PassKind.NORMAL
## Monotonic per-player kick counter -- lets a test detect "a kick happened
## this frame" without polling ball velocity.
var kick_count: int = 0

## v0.8.3: the ball-carrier decision, made observable. The playtest could
## not tell shots from passes on screen; these make the reasoning itself
## inspectable from a test or the F3 overlay rather than something that has
## to be inferred from outcomes. Written by
## AIController._decide_possession_action; never read by gameplay.
var last_shoot_score: float = 0.0
var last_shoot_threshold: float = 0.0
var last_pass_score: float = 0.0
var last_pass_threshold: float = 0.0

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
## v0.8.3: the TeamPlan.Duty this player was allocated by the team layer on
## the most recent frame (see TeamPlan). Written by TeamPlan only; read by
## AIController to build the movement target, and by tests/the debug
## overlay to assert things like "at most two players hold RUN_BEHIND".
var ai_duty: int = TeamPlan.Duty.COVER_SPACE
## Smoothed movement target. AIController writes the raw intent to
## ai_target and this is the low-pass-filtered point actually steered
## toward -- see AIController.TARGET_SMOOTH_TIME.
var ai_smoothed_target: Vector3 = Vector3.ZERO

## v0.9.1.1: the goalkeeper's current intention (AIController.GKIntent).
## Written by update_goalkeeper, read by tests and diagnostics only --
## nothing in the simulation branches on it.
var gk_intent: int = 0

## v0.9.2: the intent the keeper's dive/block animation was last fired for, so
## a keeper holding SAVE across many frames restarts the clip once, not once
## per frame. Visual bookkeeping only.
var _last_gk_intent: int = -1

## How far away the ball has to be before a keeper with nothing to do starts
## organising the defence rather than standing. Comfortably outside the
## penalty area, so it never competes with a real threat.
const GK_ORGANISE_DISTANCE := 22.0

## v0.9.1.1: the FULL carrier decision, every time one is made.
##
## Diagnostic and test surface only; nothing in the simulation reads it. The
## brief asks for the utility of every candidate action and the reason the
## alternatives lost, not just the winner -- a decision log that only records
## what happened cannot explain why a clear shot became a backward pass.
##
## Fields: player, role, position, dist_to_goal, angle_to_goal, shot_lane,
## defenders_near, keeper_dist, pressure, opportunity, options (an Array of
## {action, utility, reason}), chosen, chosen_reason.
signal decision_made(info: Dictionary)

## v0.9.2.1: a committed slide tackle finished, with what it actually did.
##
##   outcome / outcome_name  SlideTackle.Outcome
##   target                  the carrier it was aimed at
##   played_ball             did the leg reach the ball
##   hit_player              was there significant body contact
##
## The outcome is decided by measured geometry in SlideTackle, never by which
## animation played.
signal slide_resolved(info: Dictionary)

## v0.9.2.1: this player was fouled and is going down. The foul FOUNDATION
## (brief section 8): the event is emitted and logged, and a full referee,
## free-kick and card system is deliberately not built here.
signal fouled(info: Dictionary)

# --- committed slide tackle state (see SlideTackle) ---
var is_sliding: bool = false
var slide_time: float = 0.0
var slide_direction: Vector3 = Vector3.ZERO
var slide_target: FootballPlayer = null
var slide_played_ball: bool = false
var slide_hit_player: bool = false
var slide_cooldown: float = 0.0
## Time still spent on the floor after a slide, before input resumes.
var slide_recovery: float = 0.0
## Time still spent knocked over after being fouled.
var stumble_time: float = 0.0
## Diagnostic only -- the last outcome this player's slide produced.
var last_slide_outcome: int = SlideTackle.Outcome.NONE
## Speed the slide is committing along slide_direction, bled off by drag.
##
## Read by SlideTackle instead of `velocity`, because move_and_slide
## overwrites velocity with what the body ACHIEVED -- which is near zero on
## the frame two capsules collide, exactly when a challenge is hardest.
var slide_speed: float = 0.0

## The last decision record, kept so a scenario test can inspect it without
## connecting a signal.
var last_decision: Dictionary = {}
var _ai_target_initialized: bool = false

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

## v0.8.4: how far through a tackle attempt this player currently is, in
## seconds of sustained full-strength challenge (see BallContest). Written
## by PossessionManager via BallContest; read by tests and the debug
## overlay. Always 0 for the player who currently has the ball.
var challenge_progress: float = 0.0

## v0.8.4: seconds left in which this player is still "in the play" they
## just made -- see post_action_involvement(). Set when a kick is executed,
## counted down every frame.
var post_action_timer: float = 0.0
var post_action_kind: int = KickKind.NONE

## Seconds this player has continuously had the ball. Read by the AI
## carrier layer so "I have been holding this too long" is a fact rather
## than a dice roll, and by tests.
var possession_time: float = 0.0

var _control_lost_timer: float = 0.0
## Time until this player may touch the ball again -- see the touch model
## constants above. Public read-only for tests/diagnostics.
var _touch_timer: float = 0.0
## Time left in which this player may take possession from outside the
## contact radius because they just won a challenge -- see CONTEST_WIN_GRACE.
var _contest_win_timer: float = 0.0
## How long the dribble has been turning without settling -- see
## TURN_BURST_DURATION.
var _turn_hold_timer: float = 0.0
## Seconds since this player last cut the ball across their body (a TURN
## touch). BallContest reads it to decide whether a committed challenger has
## just been beaten -- see BEATEN_BY_TURN_WINDOW there.
var time_since_turn_touch: float = 999.0
## Set for one frame whenever a touch actually lands, so tests and the
## animation layer can see individual touches rather than a continuous pull.
var touched_ball_this_frame: bool = false
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

	_connect_animation_events()


## v0.9.2: let the animation layer listen to the events v0.9.1 already emits.
##
## Deliberately a subscription rather than calls added at the emit sites. The
## rule those signals were written under -- "the simulation emits and never
## reads" -- is what keeps the animation from becoming a second physics
## system (brief section 3), and it only holds if the physics code stays
## unaware of who is listening. Nothing below can influence the ball.
func _connect_animation_events() -> void:
	if animation_controller == null:
		return
	ball_touched.connect(_on_touch_animate)
	challenge_started.connect(_on_challenge_animate)
	possession_changed.connect(_on_possession_animate)


## ONE gameplay contact produces ONE animation request (brief section 8).
##
## Plain DRIBBLE knock-ons are deliberately NOT given an action clip. They
## fire every 0.3-0.5s while carrying, and the shortest usable touch clip in
## the pack still runs 0.45s, so a full-body clip per knock-on would replace
## the run cycle almost continuously -- the carrier would stop looking like a
## person running and start looking like a person repeatedly kneeing the air.
## The run cycle already contains a foot cycle. TURN and STOP are real,
## distinct and comparatively rare events, and do get their own clip.
## Ball height at contact that reads as a header rather than a foot strike,
## and the band below it that reads as a volley. Measured against the 1.6m
## character height the whole game is calibrated around.
const HEADER_CONTACT_HEIGHT := 1.15
const VOLLEY_CONTACT_HEIGHT := 0.55


func _on_touch_animate(info: Dictionary) -> void:
	var height: float = (info.get("point", global_position) as Vector3).y
	var pace: float = Vector2(velocity.x, velocity.z).length()
	match int(info.get("kind", -1)):
		TouchKind.PASS:
			animation_controller.play_action(
				"distribute_pass" if is_goalkeeper else _strike_intent(height, pace, false))
		TouchKind.SHOT:
			# A keeper with the ball clears it; update_goalkeeper routes that
			# through execute_shot, so this is the keeper's distribution.
			animation_controller.play_action(
				"distribute_kick" if is_goalkeeper else _strike_intent(height, pace, true))
		TouchKind.STOP:
			if not is_goalkeeper:
				animation_controller.play_action("trap")
		TouchKind.TURN:
			if not is_goalkeeper:
				animation_controller.play_action("touch")


## Which strike the contact was, from where the ball actually was and how fast
## the player was going -- not from which button produced it. A ball at head
## height is headed whether it was meant as a pass or a shot.
func _strike_intent(height: float, pace: float, is_shot: bool) -> String:
	if height >= HEADER_CONTACT_HEIGHT:
		return "header"
	if is_shot and height >= VOLLEY_CONTACT_HEIGHT:
		return "shoot_volley"
	if is_shot and pace > base_speed * 0.7:
		return "shoot_running"
	return "shoot" if is_shot else "pass"


## Gaining the ball is worth showing: an outfield player brings a moving ball
## under control, a keeper gathers it.
func _on_possession_animate(info: Dictionary) -> void:
	if str(info.get("kind", "")) != "gained":
		return
	if is_goalkeeper:
		# Off the ground is a catch; along the ground is a scoop.
		var ball: RigidBody3D = _known_ball
		var high: bool = ball != null and ball.global_position.y > VOLLEY_CONTACT_HEIGHT
		animation_controller.play_action("catch" if high else "scoop")
		return
	# Only worth a settle animation if the ball actually arrived at pace; a
	# ball already at your feet does not need receiving.
	var ball_ref: RigidBody3D = _known_ball
	if ball_ref != null and _relative_ball_speed(ball_ref) > CONTROLLED_BALL_SPEED * 0.5:
		animation_controller.play_action("receive")


## A challenge is the one outfield action with real lead time: BallContest
## emits this when progress starts building, well before the outcome is
## known, so the tackle clip can play its wind-up honestly.
func _on_challenge_animate(_info: Dictionary) -> void:
	var moving: float = Vector2(velocity.x, velocity.z).length()
	animation_controller.play_action(
		"challenge_slide" if moving > base_speed * 0.85 else "challenge")


func apply_player_data(data: PlayerData) -> void:
	player_data = data
	base_speed = data.movement_speed
	sprint_speed = data.sprint_speed
	acceleration = data.acceleration

	max_stamina = data.stamina
	current_stamina = max_stamina

	# v0.8.3: a shot is always decisively harder than any pass, by
	# construction -- the whole shot band sits above PassEvaluator's whole
	# pass band, so no combination of stats can make a good passer's ball
	# read like a poor shooter's. Shooting stat moves a player within the
	# shot band; it can never drag them out of it.
	pass_speed_scale = lerp(0.9, 1.1, data.passing / 100.0)
	shoot_min_speed = lerp(SHOT_SPEED_MIN, SHOT_SPEED_MIN + 1.5, data.shooting / 100.0)
	shoot_max_speed = lerp(SHOT_SPEED_MAX - 2.0, SHOT_SPEED_MAX, data.shooting / 100.0)
	# v0.8.6: softened from lerp(16, 30). See the dribble block above -- at
	# that stiffness the spring reached its 18 m/s^2 clamp within ~0.6m of
	# error, so the ball was effectively pinned rather than steered. The
	# dribbling stat still spans the same relative range, so a good dribbler
	# keeps the ball noticeably tighter than a poor one.
	dribble_accel = lerp(16.0, 30.0, data.dribbling / 100.0)
	control_loss_angle_threshold = lerp(0.9, 1.5, data.dribbling / 100.0)

	if name_label:
		name_label.text = data.display_name

	if animation_controller:
		animation_controller.set_visual(data.visual_id)
		animation_controller.set_keeper(is_goalkeeper)

	personality = PersonalityProfiles.get_profile(data.visual_id)

	if control_area:
		var shape_node: CollisionShape3D = control_area.get_node("CollisionShape3D")
		if shape_node and shape_node.shape:
			var shape: SphereShape3D = shape_node.shape.duplicate()
			# v0.8.7: this line overwrites whatever FootballPlayer.tscn says,
			# for every player spawned with player_data -- i.e. everyone in a
			# real match -- so the scene's ControlArea radius is dead config
			# and editing it does nothing. That cost real debugging time, so
			# the coupling is now explicit: the close-control sensor is
			# derived from the dribble leash it has to contain.
			#
			# It must sit clearly OUTSIDE dribble_distance_sprint. The old
			# band (0.95-1.35) was below it, so a carrier running at pace
			# knocked the ball straight out of their own possession sensor
			# and was dispossessed by their own touch -- measured: 0 of 120
			# frames in possession at a walking 5.6 m/s, because a
			# speed_ratio of 0.66 already puts the leash at 1.42m.
			# Better defenders still get the slightly wider bubble the
			# original lerp was expressing.
			var floor_radius: float = dribble_distance_sprint * CONTROL_RADIUS_LEASH_MARGIN
			shape.radius = floor_radius + lerp(0.0, 0.35, data.defensive_ability / 100.0)
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


## Wired once by MatchManager right after both TeamControllers are set up.
## The TeamPlan instance is created once and mutated in place each frame, so
## this reference stays current for the whole match.
func set_team_plan(p_plan: TeamPlan) -> void:
	team_plan = p_plan


func set_team_color(color: Color) -> void:
	if animation_controller:
		animation_controller.set_team_color(color)
	_tint_team_ring(color)


## The ground ring is unlit and emissive so it reads the same in shadow as
## in sunlight, and stays legible on a phone screen at match camera distance.
func _tint_team_ring(color: Color) -> void:
	if team_ring == null:
		return
	var mat: StandardMaterial3D = team_ring.get_surface_override_material(0)
	if mat == null:
		return
	mat = mat.duplicate()
	mat.albedo_color = Color(color.r, color.g, color.b, 0.8)
	mat.emission = color
	team_ring.set_surface_override_material(0, mat)


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
## v0.9.0: this is the REACTION only. It no longer opens the contact-gate
## exemption -- see notify_contest_won() for the narrow case that does.
##
## That exemption exists for one specific situation: a tackler collecting
## the ball they just poked away. But PossessionManager calls THIS on every
## opponent carrier change, including a player who merely got to a ball the
## other side had already lost, so granting it here handed a 0.6s window
## with the contact requirement switched OFF to essentially everyone who
## ever became carrier. Measured over a live match, 42% of all acquisitions
## then happened beyond POSSESSION_CONTACT_RADIUS, worst 1.97m -- the full
## control radius. v0.8.8's headline gate was inoperative almost half the
## time, which is the "AI steals from unrealistic distances" the human
## playtest kept reporting while the automated suite stayed green: that
## suite measured contact acquisitions and kick distances, both correctly
## gated, and never measured the acquisition frame itself.
func notify_possession_won_from_opponent() -> void:
	if animation_controller == null:
		return
	# v0.9.2.1: a keeper who takes the ball off an opponent has already
	# played a catch or a scoop from possession_changed, and "tackle" is an
	# OUTFIELD intent -- asking for it here was the one real role leak the
	# live-match check found, which is exactly the class of mistake the role
	# gate exists to catch rather than to hide.
	if is_goalkeeper:
		return
	# A notably competitive/aggressive character reacts more visibly to
	# winning the ball than a plain "tackle" animation implies.
	if personality.competitiveness > 75.0 or personality.aggression > 75.0:
		animation_controller.play_action("excited_reaction")
	else:
		animation_controller.play_action("tackle")


## Won an actual CHALLENGE -- BallContest resolved a tackle in this player's
## favour. This is the one case that may collect the ball from outside
## contact range, because _apply_tackle knocks the ball TOWARD the winner
## rather than into their feet, so they are legitimately a stride from it on
## the frame they win it.
##
## Still bounded: the exemption stretches the contact radius to
## CONTEST_WIN_REACH, it does not remove it. A tackler may collect a ball
## they knocked a stride away; nobody may collect one that is not there.
func notify_contest_won() -> void:
	_contest_win_timer = CONTEST_WIN_GRACE
	notify_possession_won_from_opponent()


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


## True while the last touch was heavy enough that the ball is running away
## from this player's feet -- the moment a defender most wants to strike.
func is_heavy_touch() -> bool:
	return _control_lost_timer > 0.0


## Called by BallContest when this player is tackled. Ends possession and
## blocks re-acquiring it (and, because the dribble spring is gated on the
## same cooldown, stops the ball being pulled straight back to their feet).
func notify_dispossessed(cooldown: float) -> void:
	if has_possession:
		_emit_possession_changed("lost", "dispossessed")
	has_possession = false
	possession_time = 0.0
	challenge_progress = 0.0
	_possession_grace_timer = 0.0
	_control_lost_timer = 0.0
	_possession_cooldown_timer = maxf(_possession_cooldown_timer, cooldown)
	just_lost_possession_window = _MOMENTARY_TRIGGER_WINDOW


## 1.0 immediately after this player shot or passed, decaying to 0 across
## POST_ACTION_WINDOW. AIController blends a follow-up position in by this
## amount, so a player who has just played the ball stays involved in the
## move instead of turning for home the instant it leaves their foot --
## and, because it decays rather than expiring, they drift back into normal
## shape smoothly rather than snapping.
func post_action_involvement() -> float:
	if post_action_timer <= 0.0 or POST_ACTION_WINDOW <= 0.0:
		return 0.0
	return clampf(post_action_timer / POST_ACTION_WINDOW, 0.0, 1.0)


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
	ai_duty = TeamPlan.Duty.COVER_SPACE
	_ai_target_initialized = false
	possession_time = 0.0
	challenge_progress = 0.0
	post_action_timer = 0.0
	post_action_kind = KickKind.NONE

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

	# v0.9.2.1: a committed slide, and being knocked over, both take the body
	# away from input for a moment. Handled here rather than by zeroing
	# move_input elsewhere so there is ONE place that decides what the body
	# is doing, and so a slide keeps carrying its momentum instead of
	# stopping dead. Commitment is the point (brief section 10): a tackler
	# who can still steer mid-slide cannot be beaten by a change of
	# direction, and then dribbling past a defender is impossible.
	if is_sliding or slide_recovery > 0.0 or stumble_time > 0.0:
		_drive_committed_body(delta)
		return


	var direction := Vector3.ZERO if movement_locked else Vector3(move_input.x, 0.0, move_input.y)

	if direction.length() > 0.01:
		var target_angle := atan2(direction.x, direction.z)
		var angle_delta := absf(wrapf(target_angle - _facing_angle, -PI, PI))
		var angle_threshold := control_loss_angle_threshold * (0.7 if sprinting else 1.0)

		if has_possession and _control_lost_timer <= 0.0 and angle_delta > angle_threshold and velocity.length() > control_loss_speed_threshold:
			_control_lost_timer = control_loss_duration

		# v0.8.3: the facing angle itself now turns at a finite rate instead
		# of snapping to the input direction while only the MODEL turned
		# smoothly. This is the root cause of "the human player's ball
		# control feels wrong/stiff" while the AI's felt fine, and it is a
		# genuine asymmetry rather than a perception problem: the dribble
		# target point is computed from _facing_angle (see
		# _update_possession), so a joystick flicked 180 degrees teleported
		# that point straight through the player to the opposite side, and
		# the spring yanked the ball across their feet. AI players never
		# triggered it because their move_input is a direction-to-a-target
		# that rotates gradually, so their facing never jumped. Now both are
		# driven by the same finite turn rate, and the ball sweeps around
		# the player instead of being snapped across them.
		_facing_angle = lerp_angle(_facing_angle, target_angle, clampf(turn_lerp_speed * delta, 0.0, 1.0))
		model.rotation.y = _facing_angle

		velocity.x = move_toward(velocity.x, direction.x * target_speed, effective_acceleration * delta)
		velocity.z = move_toward(velocity.z, direction.z * target_speed, effective_acceleration * delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, deceleration * delta)
		velocity.z = move_toward(velocity.z, 0.0, deceleration * delta)

	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= gravity * delta

	# Captured BEFORE move_and_slide, which overwrites `velocity` with what
	# the body actually achieved -- and what it achieves when it runs into
	# the ball is close to zero, which is the very thing being fixed below.
	# The shove has to be driven by the speed the player was TRYING to move
	# at, not the speed the ball just denied them.
	var intended_velocity: Vector3 = velocity
	var pre_move_y: float = global_position.y
	var was_grounded: bool = is_on_floor()

	move_and_slide()

	_push_ball_on_contact(intended_velocity)
	# Nothing in this game jumps, and the pitch is flat, so a player who was
	# on the ground before moving must still be on it afterwards. Without
	# this a player running onto the ball RIDES UP IT -- a capsule sliding
	# over a 0.35m sphere is redirected upward by the contact normal, and
	# measured with the shove above enabled a sprinting carrier climbed to
	# y=1.1 and was then flung off by the depenetration at 26 m/s against a
	# sprint speed of 8.5. Constraining the plane is exact here rather than
	# approximate, and it leaves the horizontal collision response -- which
	# is what actually keeps the ball in front of a dribbler -- untouched.
	if was_grounded and global_position.y > pre_move_y:
		global_position.y = pre_move_y
		velocity.y = 0.0

	_update_possession(sprinting, stamina_ratio, delta)
	_process_pass_input()
	_process_shoot_input(delta)
	_update_animation_state()
	_update_personality_bookkeeping(delta)

	if has_possession:
		possession_time += delta
	else:
		possession_time = 0.0
	# NOTE: challenge_progress is owned entirely by BallContest (which
	# decays it for the carrier and for anyone not actually challenging).
	# It must NOT be cleared on has_possession here: that flag is purely
	# local -- a challenger standing over the ball has it set too, because
	# the ball is inside their own control radius -- so doing so wiped
	# every challenger's progress on the very frame they got close enough
	# to matter, and no tackle could ever complete.

	if post_action_timer > 0.0:
		post_action_timer = maxf(0.0, post_action_timer - delta)

	if _control_lost_timer > 0.0:
		_control_lost_timer = maxf(0.0, _control_lost_timer - delta)
	if _contest_win_timer > 0.0:
		_contest_win_timer = maxf(0.0, _contest_win_timer - delta)
	time_since_turn_touch += delta
	if _possession_cooldown_timer > 0.0:
		_possession_cooldown_timer = maxf(0.0, _possession_cooldown_timer - delta)
	if _possession_grace_timer > 0.0:
		_possession_grace_timer = maxf(0.0, _possession_grace_timer - delta)


## v0.8.6: let a player actually SHOVE the ball they run into.
##
## This is a root cause of "human ball control is stiff / the ball feels
## rigid and hard to interact with", and it is not a tuning problem. A
## CharacterBody3D does not push RigidBody3Ds -- Godot simply stops it dead
## against them, and the player's collision_mask includes the ball's layer.
## So a carrier was being physically braked by a 0.45kg football: measured in
## an isolated 1v0, a player told to sprint in a straight line with the ball
## at their feet reached 0.9 m/s against a base speed of 5.0 and a sprint
## speed of 8.5. Dribbling was not "carrying the ball", it was grinding along
## behind an obstacle -- which is exactly what "rigid" describes, and it is
## why the ball could never be seen to run ahead, lag, or be knocked off line.
##
## The shove is the impulse that brings the ball up to the player's own speed
## along the contact normal, capped per frame. That makes it self-limiting (a
## ball already travelling with the player receives nothing), keeps the ball a
## fully simulated body rather than something dragged, and changes no
## collision shape: opponents still knock it, contests are still physical.
func _push_ball_on_contact(intended_velocity: Vector3) -> void:
	for i in range(get_slide_collision_count()):
		var collision: KinematicCollision3D = get_slide_collision(i)
		var collider: Object = collision.get_collider()
		if not (collider is RigidBody3D) or not collider.is_in_group("ball"):
			continue
		var push_dir: Vector3 = -collision.get_normal()
		push_dir.y = 0.0
		if push_dir.length() < 0.01:
			continue
		push_dir = push_dir.normalized()
		var player_along: float = Vector3(intended_velocity.x, 0.0, intended_velocity.z).dot(push_dir)
		if player_along <= 0.0:
			continue
		# Only a player actively driving into the ball shoves it. A player
		# coasting to a stop still carries real velocity for a few tenths of
		# a second, and letting that boot the ball away meant a stationary
		# player could nudge it several metres after releasing the stick.
		if move_input.length() <= 0.1:
			continue
		var ball_along: float = collider.linear_velocity.dot(push_dir)
		if ball_along >= player_along:
			continue
		collider.apply_central_impulse(push_dir * minf(player_along - ball_along, BALL_PUSH_MAX_DELTA_V) * collider.mass)


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
	# v0.9.2 (brief section 5): the animation layer is driven by what the
	# CharacterBody actually did this frame, not by the input that asked for
	# it and not by a state name. A player being shoved backwards while
	# facing forwards gets the backpedal clip because that is what is
	# happening to them.
	animation_controller.set_motion(velocity)
	_update_keeper_animation()
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


## v0.9.2 (brief section 26): the keeper's DECISIONS are untouched. This reads
## the intent AIController already computed and shows it; a dive fires when
## the keeper commits to SAVE, a block when it commits to BLOCK, and nothing
## fires for POSITION, CLOSE_ANGLE or ATTACK_LOOSE_BALL, which are just
## running and are already covered by locomotion.
##
## Firing on the TRANSITION, not on the state, is what stops a keeper holding
## SAVE for half a second from restarting the dive clip thirty times.
func _update_keeper_animation() -> void:
	if not is_goalkeeper:
		return
	if gk_intent == _last_gk_intent:
		return
	var previous: int = _last_gk_intent
	_last_gk_intent = gk_intent
	match gk_intent:
		AIController.GKIntent.SAVE:
			# Which way to dive comes from where the ball actually is
			# relative to the way the keeper is facing.
			animation_controller.play_action(
				"save_right" if _ball_is_to_the_right() else "save_left")
		AIController.GKIntent.BLOCK:
			animation_controller.play_action("block")
		AIController.GKIntent.CLOSE_ANGLE:
			# Shuffling across to narrow the angle, not a committed dive.
			animation_controller.play_action(
				"sidestep_right" if _ball_is_to_the_right() else "sidestep_left")
		AIController.GKIntent.RECOVER:
			animation_controller.play_action("place_ball")
		AIController.GKIntent.POSITION:
			# Coming off a committed save without the ball means it went past:
			# that is the keeper being beaten, and it has its own clip.
			if previous == AIController.GKIntent.SAVE and not has_possession:
				animation_controller.play_action("gk_miss")
			elif _ball_is_far_upfield():
				# Play is nowhere near: organise the defence. This is the
				# keeper's most common state by far and it used to be a
				# static idle.
				animation_controller.play_action("gk_organise")
		_:
			# ATTACK_LOOSE_BALL is running, which locomotion already covers.
			pass


## Is play far enough away that the keeper has nothing to react to?
func _ball_is_far_upfield() -> bool:
	var ball: RigidBody3D = _known_ball
	if ball == null:
		return true
	return global_position.distance_to(ball.global_position) > GK_ORGANISE_DISTANCE


## Move the body while it is not taking input: mid-slide, recovering from one,
## or knocked over.
##
## Momentum is preserved and bled off rather than cancelled -- a slide that
## stopped dead would be a pose, not a slide, and the carrier could not run
## past a committed defender. Gravity and move_and_slide still run, so the
## body stays on the floor and keeps colliding with everyone normally.
func _drive_committed_body(delta: float) -> void:
	if is_sliding:
		slide_speed = maxf(0.0, slide_speed - SlideTackle.SLIDE_DRAG * delta)
		velocity.x = slide_direction.x * slide_speed
		velocity.z = slide_direction.z * slide_speed
	else:
		# Down, or picking yourself up: no self-propulsion at all.
		#
		# The timers are counted down HERE, by the player itself, rather than
		# by SlideTackle.update. A knocked-over player must get back up
		# because time passed, not because some other system happened to be
		# running that frame -- section 9 is explicit that no reaction may
		# permanently freeze a player, and a timer owned by someone else is
		# exactly how that happens.
		var was_down: bool = stumble_time > 0.0 or slide_recovery > 0.0
		stumble_time = maxf(0.0, stumble_time - delta)
		slide_recovery = maxf(0.0, slide_recovery - delta)
		velocity.x = move_toward(velocity.x, 0.0, deceleration * 2.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, deceleration * 2.0 * delta)
		# The moment the last timer runs out, get up. Fired here so the
		# recovery clip plays exactly once, on the frame control returns,
		# rather than every frame the player happens to be down.
		if was_down and stumble_time <= 0.0 and slide_recovery <= 0.0 and animation_controller:
			animation_controller.play_action("get_up")

	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= gravity * delta
	move_and_slide()
	_update_animation_state()


## Commit to a slide tackle at `target`. The direction is locked in HERE and
## never revisited, which is what gives the carrier something to beat.
func begin_slide(target: FootballPlayer) -> void:
	if is_sliding:
		return
	var to_target: Vector3 = target.global_position - global_position
	to_target.y = 0.0
	if to_target.length() < 0.01:
		return
	# Aim at where the carrier is GOING, not where they are: a slide that
	# aims at the current position always arrives behind a moving player.
	var lead: Vector3 = to_target + Vector3(target.velocity.x, 0.0, target.velocity.z) * 0.18
	is_sliding = true
	slide_direction = lead.normalized()
	slide_target = target
	slide_time = 0.0
	slide_played_ball = false
	slide_hit_player = false
	slide_speed = SlideTackle.SLIDE_SPEED
	_facing_angle = atan2(slide_direction.x, slide_direction.z)
	model.rotation.y = _facing_angle
	challenge_started.emit({
		"kind": "slide",
		"target": target,
		"position": global_position,
		"direction": slide_direction,
		"strength": 1.0,
	})
	if animation_controller:
		animation_controller.play_action("challenge_slide")


## Knocked over. Temporary by construction: `stumble_time` counts down and
## nothing else can extend it, so a fouled player always gets back up
## (brief section 9 -- no reaction may permanently freeze control or AI).
func begin_stumble(duration: float) -> void:
	stumble_time = maxf(stumble_time, duration)
	move_input = Vector2.ZERO
	sprint_requested = false
	if animation_controller:
		animation_controller.play_action("tripped")
	fouled.emit({
		"position": global_position,
		"duration": duration,
	})


## Called by SlideTackle when a committed slide produces its outcome.
func notify_slide_resolved(outcome: int, target: FootballPlayer) -> void:
	last_slide_outcome = outcome
	slide_target = null
	if outcome == SlideTackle.Outcome.CLEAN:
		notify_contest_won()
	slide_resolved.emit({
		"outcome": outcome,
		"outcome_name": SlideTackle.outcome_name(outcome),
		"target": target,
		"position": global_position,
		"played_ball": slide_played_ball,
		"hit_player": slide_hit_player,
	})


## Sign of the ball's offset across the keeper's facing direction.
func _ball_is_to_the_right() -> bool:
	var ball: RigidBody3D = _known_ball
	if ball == null:
		return true
	return player_right().dot(ball.global_position - global_position) >= 0.0


## The player's own RIGHT on the ground plane.
##
## v0.9.2: right = forward x up. Godot is right-handed with a node's forward
## at -Z, and this project faces players along +Z instead, so the model's axes
## run opposite to the usual reading and the character's right is -X when
## facing +Z -- not +X, which is what the obvious perpendicular gives.
##
## The distinction is invisible until something is authored for a real
## anatomical side. Both callers are: which foot a touch reads as, and which
## way a keeper dives. Getting it backwards would have every keeper dive away
## from the ball.
func player_right() -> Vector3:
	var facing := facing_direction()
	return Vector3(-facing.z, 0.0, facing.x)


func _get_aim_direction() -> Vector3:
	if move_input.length() > 0.15:
		return Vector3(move_input.x, 0.0, move_input.y).normalized()
	return facing_direction()


## Which way this player is actually LOOKING, as a unit vector on the ground.
##
## v0.9.1. Necessary because the BODY does not turn: _facing_angle is applied
## to `model.rotation.y`, so the CharacterBody3D's own basis keeps whatever
## orientation it was spawned with, for the whole match. Anything outside
## this script that reached for global_transform.basis.z to find a facing was
## therefore reading the spawn orientation rather than the player.
##
## That is not hypothetical -- BallContest.within_poke_envelope was written
## that way, and it silently refused legitimate tackles by any stationary
## defender whose ball happened to lie on the wrong side of world +Z.
## Measured: v0_8_4's "a sustained challenge on a stationary carrier
## completes as a tackle" and v0_8_8's "a challenger who actually reaches the
## ball can still win it" both went red, in constructed duels where the
## defender was demonstrably on top of the ball.
func facing_direction() -> Vector3:
	return Vector3(sin(_facing_angle), 0.0, cos(_facing_angle))


# Soft-attach steering: nudges the ball toward a point just ahead of the
# player with a spring/damper force. The ball stays a fully simulated
# RigidBody3D at all times -- this only adds a force on top of normal
# physics, so collisions, bounces, and knock-aways still behave naturally.
## Announce a ball contact -- see the `ball_touched` signal.
##
## Deliberately cheap and side-effect free: it builds one Dictionary and
## emits. With no listener connected this is a few microseconds and changes
## nothing about the simulation, which is what lets the physics ship before
## the animation system exists.
func _emit_touch(kind: int, direction: Vector3, strength: float, ball: RigidBody3D) -> void:
	if ball == null:
		return
	# Which foot the contact reads as: the ball's side relative to the way
	# the player is facing. An animation layer needs this to pick a clip;
	# nothing in the physics uses it.
	var side: Vector3 = ball.global_position - global_position
	var right: Vector3 = player_right()
	ball_touched.emit({
		"kind": kind,
		"point": ball.global_position,
		"direction": direction,
		"strength": strength,
		"distance": Vector2(side.x, side.z).length(),
		"player_velocity": velocity,
		"foot": "right" if right.dot(side) >= 0.0 else "left",
	})


## Is the ball within `limit` metres, measured on the ground plane?
##
## Used while the ball is OUTSIDE the close-control sensor, so it cannot read
## ball_in_control_range. The ActionArea reference (2.5m) still resolves in
## that band; a ball beyond even that is unambiguously gone, and answering
## false is correct.
func _ball_within(limit: float) -> bool:
	var b: RigidBody3D = ball_in_control_range
	if b == null:
		b = ball_in_action_range
	if b == null:
		b = _known_ball
	if b == null or not is_instance_valid(b):
		# "I cannot tell" is not "it is far away". Answering false here drops
		# possession on any frame the ball is repositioned, because Area3D
		# references only refresh on the next physics step -- that regressed
		# v0_8_2's explicit assertion that a one-frame excursion outside the
		# control radius does NOT drop possession (the very case the grace
		# exists for), and took v0_8_3's whole kick-instrumentation block
		# with it.
		return true
	return Vector2(b.global_position.x - global_position.x,
		b.global_position.z - global_position.z).length() <= limit


func _update_possession(sprinting: bool, stamina_ratio: float = 1.0, delta: float = 0.0) -> void:
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
		# v0.9.0: the grace is a smoother, not a tether. It exists so the
		# flag does not chatter while the ball sits on the sensor boundary,
		# and it must not keep saying "his" about a ball that has genuinely
		# gone -- see RETAIN_MAX_DISTANCE for the measured tail it cuts off.
		if has_possession and _possession_grace_timer > 0.0 and _ball_within(RETAIN_MAX_DISTANCE):
			return
		# Possession genuinely ends here (grace expired, and this wasn't a
		# deliberate kick -- that path returned above on the cooldown), so
		# this is the correct place to arm the "lost possession"
		# personality trigger. Firing it the instant the ball crossed the
		# radius instead would cry wolf on every touch the grace absorbs.
		if has_possession:
			just_lost_possession_window = _MOMENTARY_TRIGGER_WINDOW
			_emit_possession_changed("lost", "ball_gone")
		has_possession = false
		return

	# v0.8.8: ACQUIRE TIGHT, RETAIN LOOSE.
	#
	# This is the root cause of "AI steals the ball from unrealistic
	# distances", and it is one flag doing two incompatible jobs.
	# has_possession answered "is the ball inside my ControlArea", and
	# ControlArea has to be wide enough to contain the dribble leash (v0.8.7
	# sized it at ~1.55-1.90m so a sprinting carrier does not knock the ball
	# out of their own possession radius). PossessionManager then elected a
	# carrier straight from that flag -- so simply standing within ~1.7m of
	# a ball someone else was dribbling won it, with no contact and no
	# challenge. Measured over a 40s match: possession changed hands between
	# opponents 40 times, the dispossessed player was on average 1.61m from
	# the ball (max 2.74m), and 40% of those steals had NO challenge built
	# at all -- pure geometry taking the ball.
	#
	# The two jobs are now separated. GAINING possession requires the ball
	# to be genuinely at your feet (POSSESSION_CONTACT_RADIUS, which is the
	# two collision shapes nearly touching) or to have just won a contest.
	# KEEPING it works out to the full control radius, so touch dribbling is
	# completely unaffected -- the ball can still be knocked 1.35m ahead.
	var ball_gap: float = Vector2(
		ball_in_control_range.global_position.x - global_position.x,
		ball_in_control_range.global_position.z - global_position.z).length()
	# v0.9.0: the contest exemption STRETCHES this radius, it does not remove
	# it -- see CONTEST_WIN_REACH. Granting an unbounded exemption is what
	# let 42% of acquisitions land outside the gate.
	var acquire_radius: float = possession_contact_radius
	if _contest_win_timer > 0.0:
		acquire_radius = maxf(acquire_radius, CONTEST_WIN_REACH)
	# v0.9.1.1: ...and you cannot simply ABSORB a ball that is travelling too
	# fast to control.
	#
	# This is the root of the goalkeeper regression human QA reported as
	# "the keeper does not attempt a save". Measured with a ball fired at a
	# stationary keeper: possession was granted at a gap of 1.05m while the
	# ball was still doing 9.58 m/s, close control then damped it, and the
	# keeper "had" a ball that had been struck at them. No save was needed
	# because none was ever required -- the shot was handed over on contact
	# with the possession radius.
	#
	# Distance decides whether you can REACH the ball; this decides whether
	# it is controllable when you get there. A faster ball has to be stopped
	# by a body first (the ball collides with players again as of this
	# milestone), which is what a block or a parry is, and can be collected
	# on the rebound once it has slowed.
	#
	# Gates ACQUISITION only. Retention is untouched, so a carrier who knocks
	# the ball ahead of themselves keeps it exactly as before -- their
	# relative speed is near zero by construction.
	if not has_possession and _relative_ball_speed(ball_in_control_range) > CONTROLLED_BALL_SPEED:
		return

	if not has_possession and ball_gap > acquire_radius:
		# Near the ball, but not on it. Keep steering nothing and let the
		# approach continue; this is the frame the old code handed the ball
		# over on.
		return

	_possession_grace_timer = POSSESSION_GRACE
	if not has_possession:
		possession_time = 0.0
		_emit_possession_changed("gained", "collected")
	has_possession = true
	# v0.9.1.1: the ball collides with players again, so the CARRIER has to
	# be excepted or close control fights its own collision -- see
	# BallController.pass_through_for. Refreshed every frame of possession;
	# it lapses on its own once the ball is clear.
	#
	# ONLY for a ball that is actually under control. The exception exists so
	# a dribble does not fight its own capsule; granting it to a ball
	# arriving at shot pace turns a body into a hole -- measured, a keeper
	# with a ball fired at them acquired possession mid-flight and the ball
	# then travelled straight through and out the other side. A ball moving
	# fast RELATIVE TO THE PLAYER has to hit them, which is what a save or a
	# block is.
	if ball_in_control_range is BallController \
		and _relative_ball_speed(ball_in_control_range) < CONTROLLED_BALL_SPEED:
		ball_in_control_range.pass_through_for(self)

	# v0.8.3: a heavy touch used to cut the steering force to exactly zero
	# for control_loss_duration, so the ball simply stopped being dribbled
	# for a third of a second on every sharp turn -- combined with the
	# snapping facing angle above, that is what made human close control
	# feel like the ball kept escaping. It now keeps a weak pull instead:
	# the ball still runs away from the player on a bad touch (it is a
	# fully simulated RigidBody3D being nudged, never attached), but it
	# stays recoverable, which is what a real heavy touch looks like.
	var control_quality := 1.0
	if _control_lost_timer > 0.0:
		control_quality = CONTROL_LOSS_STEER_SCALE

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

	# v0.8.7: accel_coeff/damping_coeff are gone with the spring they drove.
	# Fatigue still degrades close control, now through the touch itself and
	# the shepherd force below rather than through a spring stiffness.
	# v0.8.6: the old `if sprinting: accel_coeff *= 0.6` produced the exact
	# opposite of the looser control it was meant to model. The ball has real
	# drag (linear_damp plus rolling friction, ~3 m/s^2 at a sprint), so the
	# spring must do continuous work just to keep it travelling with the
	# player at all; weakening the spring at precisely the moment that work
	# is highest meant the ball fell BEHIND its target point, was overrun by
	# the player, and ended up NEARER them at a sprint than at a standstill
	# -- measured 0.74m sprinting against 0.89m stationary. The parameter
	# named dribble_distance_sprint was, in practice, a tighter leash.
	#
	# Looser control at pace is now carried by the one thing that actually
	# expresses it: the ball is targeted further out in front. That is more
	# visible, and it is what genuinely makes a sprinting carrier easier to
	# dispossess (BallContest scores a challenger on their distance to the
	# BALL).

	# Close at a standstill/walk, knocked further ahead while sprinting --
	# "sprinting should loosen control" per the brief -- driven off actual
	# current speed (not just the sprinting flag) so the transition itself
	# feels smooth rather than an instant step.
	# v0.8.7: measured from BASE speed up to sprint speed, not from a
	# standstill. Against a standstill, simply running at normal pace
	# (base_speed 5.6 against sprint_speed 8.5) already scored 0.66 and drew
	# the leash out to 1.42m, so "walking" close control was in practice
	# almost fully loosened and the ball sat further away at a jog than at a
	# sprint (measured 2.20m vs 1.06m -- backwards).
	var pace_span: float = maxf(sprint_speed - base_speed, 0.01)
	var speed_ratio: float = clampf((velocity.length() - base_speed) / pace_span, 0.0, 1.0)
	var current_dribble_distance: float = lerp(dribble_distance, dribble_distance_sprint, speed_ratio)

	# v0.8.7: TOUCHES, not a spring. See the touch-model constants above for
	# why the old every-frame spring was permanent attachment by
	# construction. `delta` is now threaded in so touches can be spaced in
	# real time rather than applied on every physics tick.
	#
	# Direction of the dribble: where the player is actually going if they
	# are going anywhere, else where they face. Using the live movement
	# direction is what lets a change of direction redirect the next touch
	# (the "fake" in the brief) without waiting for the facing angle -- a
	# deliberately rate-limited value -- to catch up to the stick.
	var facing_dir := Vector3(sin(_facing_angle), 0.0, cos(_facing_angle))
	var dribble_dir: Vector3 = facing_dir
	if move_input.length() > 0.15:
		dribble_dir = Vector3(move_input.x, 0.0, move_input.y).normalized()

	var ball_body: RigidBody3D = ball_in_control_range
	var ball_vel: Vector3 = ball_body.linear_velocity
	var horizontal_vel := Vector3(ball_vel.x, 0.0, ball_vel.z)
	var to_ball: Vector3 = ball_body.global_position - global_position
	to_ball.y = 0.0

	# Decompose the ball's offset into "along the dribble" and "off to the
	# side". The two halves are driven by completely different mechanisms:
	# touches drive the first, shepherding only ever corrects the second.
	var ahead: float = to_ball.dot(dribble_dir)
	var lateral: Vector3 = to_ball - dribble_dir * ahead

	_touch_timer = maxf(0.0, _touch_timer - delta)

	# A turn is measured against where the ball is actually TRAVELLING, not
	# where it sits: a ball rolling left while the player now wants to go
	# right needs a fresh touch even though it may still be dead ahead.
	var turning := false
	if horizontal_vel.length() > 0.6:
		turning = horizontal_vel.normalized().angle_to(dribble_dir) > TOUCH_TURN_ANGLE

	# v0.9.0: how long this turn has been going on. One touch cannot fully
	# redirect a rolling ball, so `turning` stays true through a sustained
	# turn -- see TURN_BURST_DURATION for what that did to touch spacing.
	# Only the opening of a turn gets the sharp re-touch; after that the
	# dribble settles into its ordinary rhythm on the new line.
	# The urgency window is armed further down, once `trailing` is known too
	# -- both conditions feed it. See TURN_BURST_DURATION.

	# Touch again once the ball has drawn back inside the leash, or as soon
	# as the dribble turns. Suppressed entirely while a heavy touch is being
	# served out, so a bad touch still genuinely costs control.
	# The ball has fallen behind, or is travelling well slower than the
	# player: both mean the carrier is running away from their own ball and
	# needs to get it back into their stride NOW rather than at the next
	# scheduled touch.
	#
	# Without this the model could not accelerate a ball from rest. A player
	# starting a sprint reaches 8.5 m/s in about half a second, while one
	# touch adds at most TOUCH_MAX_DELTA_V and the next is 16-25 frames
	# away, so the ball simply never caught up: measured in the isolated
	# close-control scene, the player hit 8.2 m/s with the ball still
	# dawdling at 1.5-4 m/s until it dropped out of the control radius
	# entirely and finished 8.5m behind.
	var ball_speed: float = horizontal_vel.length()
	var player_speed: float = Vector2(velocity.x, velocity.z).length()
	var trailing: bool = ahead < 0.0 or ball_speed < player_speed - TOUCH_TRAIL_SPEED_GAP

	var wants_touch: bool = ahead < current_dribble_distance * TOUCH_TRIGGER_RATIO or turning or trailing
	var interval: float = lerp(TOUCH_INTERVAL_WALK, TOUCH_INTERVAL_SPRINT, speed_ratio)
	# v0.9.0: `turn_burst`, not `turning` -- only the OPENING of a turn earns
	# the short interval. See TURN_BURST_DURATION.
	# v0.9.0: urgency earns a FAST REACTION, not a permanently high touch
	# rate. `turning` and `trailing` both stay true for as long as a turn
	# lasts -- a redirected ball really is slower than the player, which is
	# what `trailing` tests -- so gating only one of them changed nothing:
	# measured, a 90-degree turn still produced 8.0 touches per second with
	# the interval pinned at its floor for the whole manoeuvre, exactly as
	# before the first attempt at this fix. Both conditions now share one
	# window: the opening of an urgent state gets the short interval, and
	# then the dribble settles back into its ordinary pace-based rhythm.
	# TRIED AND REVERTED: sharing this window with `trailing` as well. It cut
	# the turn to 2 touches, and cost possession outright -- the carrier held
	# the ball for 35 of 120 frames and then lost it for good, because
	# `trailing` is not a cosmetic urgency signal but the mechanism that
	# catches a ball which is genuinely escaping. Time-limiting that means
	# never recovering it. Only `turning` is windowed; `trailing` runs until
	# it is resolved, and the touch RATE is bounded by the floor instead.
	if turning:
		_turn_hold_timer += delta
	else:
		_turn_hold_timer = 0.0
	var turn_burst: bool = turning and _turn_hold_timer <= TURN_BURST_DURATION
	if turn_burst or trailing:
		interval = minf(interval, TOUCH_INTERVAL_TURN)
		# Shorten the timer ALREADY RUNNING, not just the next one. A touch
		# taken while everything was fine sets a full-length interval, and
		# the situation can turn urgent a frame later; without this the
		# player had to wait out the old interval before reacting, which is
		# why a ball falling behind during a sprint only got four touches in
		# two seconds and was never recovered.
		_touch_timer = minf(_touch_timer, TOUCH_INTERVAL_TURN)
	# The larger redirect allowance likewise belongs to the opening contact:
	# that is the touch which has to kill the ball's old momentum. Later
	# touches on the new line are ordinary ones.
	var turn_touch: bool = turn_burst

	# A player who is not trying to go anywhere is not knocking the ball out
	# in front of themselves -- they are keeping it at their feet, which the
	# lateral shepherding below already does. Without this a stationary
	# player stood beside a resting ball still "dribbled" it away, which a
	# regression test correctly caught as a phantom shot.
	#
	# Note this is deliberately NOT a test for the ball being in front. When
	# a player turns, the ball is briefly behind the new direction by
	# definition, and refusing to touch it there means a sideways dribble
	# never picks the ball up again -- measured, it simply abandoned it.
	# Touching a ball that is behind you is fine; what is not fine is
	# sizing that touch off a gap larger than the leash itself, which is
	# what produced the phantom shot's full-power knock. The gap is clamped
	# at the touch site instead.
	# INTENT, not momentum. A player is dribbling when they are trying to go
	# somewhere; a player coasting to a stop is not, and must not keep
	# knocking the ball on.
	#
	# Accepting residual speed here (`or player_speed > 0.5`) was wrong twice
	# over. It counted a player still settling onto the ground under gravity
	# as dribbling, so a resting ball crept away at 1.3 m/s. Worse, it kept
	# the catch-up touch alive through a player's whole deceleration: with
	# the stick released, `trailing` stayed true because the ball was slower
	# than the still-moving player, so touch after touch pushed the ball on
	# while the player slowed. Measured, a carrier who stopped ended up with
	# the ball 3.45m away at 4 m/s -- outside their own control radius, so
	# the next PASS found no ball at all and silently did nothing.
	var has_dribble_intent: bool = move_input.length() > 0.15

	# v0.9.0: STOPPING is a football action, and it needs its own touch.
	#
	# The comment above is right that a coasting player must not keep
	# knocking the ball ON -- that is what put the ball 3.45m ahead. But
	# doing nothing at all is not the alternative a real player has: they
	# put a foot on it. Measured in the isolated close-control scene, a
	# carrier releasing the stick took ZERO further touches and the ball
	# rolled out to 1.64m -- from a walking leash of 0.85m -- still moving
	# faster than the player the whole way. "Stop with the ball" was in the
	# brief's list of things the player should be able to do, and it was the
	# one manoeuvre that simply lost possession.
	#
	# So a player who has stopped, with the ball running away from them,
	# gets a KILLING touch: it damps the ball rather than driving it, aimed
	# back toward their own feet. Distinct from the settle force below,
	# which is a continuous damper -- this is a discrete contact, spaced by
	# the same timer, and it emits a touch event like any other.
	var stopping: bool = not has_dribble_intent and ball_speed > STOP_TOUCH_MIN_BALL_SPEED \
		and ahead > 0.0 and player_speed < STOP_TOUCH_MAX_PLAYER_SPEED

	touched_ball_this_frame = false
	if stopping and _touch_timer <= 0.0:
		# Toward the player's feet, at a speed that brings the ball back
		# rather than stopping it dead where it is -- a ball killed in place
		# is one that stays a metre away.
		var back := Vector3(-to_ball.x, 0.0, -to_ball.z)
		var back_dir: Vector3 = back.normalized() if back.length() > 0.01 else Vector3.ZERO
		var want: Vector3 = back_dir * minf(STOP_TOUCH_RETURN_SPEED, ahead / STOP_TOUCH_INTERVAL)
		var stop_dv: Vector3 = want - horizontal_vel
		stop_dv = stop_dv.limit_length(TOUCH_MAX_DELTA_V)
		ball_body.apply_central_impulse(stop_dv * ball_body.mass)
		_touch_timer = STOP_TOUCH_INTERVAL
		touched_ball_this_frame = true
		_emit_touch(TouchKind.STOP, back_dir, stop_dv.length(), ball_body)

	if wants_touch and has_dribble_intent and _touch_timer <= 0.0:
		# Strength of the touch is set by the CORRECTION it has to make: how
		# much further ahead the ball ought to be, spread over the interval
		# until the next touch. The ball therefore travels with the player
		# and closes the gap, instead of being launched.
		#
		# A flat multiple of the player's speed (the first attempt here, at
		# 1.14x) does not work: it makes the touch stronger exactly as the
		# player gets faster, so with a short walking leash the ball simply
		# outran the carrier -- measured, the ball reached 7.5m ahead and
		# possession survived 26 of 120 frames at a walk.
		# Clamped to the leash: a ball behind the player (negative `ahead`)
		# would otherwise ask for a correction bigger than the whole dribble
		# distance and come out at the full delta cap -- a kick, not a touch.
		var gap: float = clampf(current_dribble_distance - ahead, 0.0, current_dribble_distance)
		# Capped by TOUCH_MAX_CLOSING, not by the delta-v ceiling. Those are
		# different quantities and conflating them broke close control at
		# pace: `closing` is how much FASTER THAN THE PLAYER the ball is
		# sent, so allowing it the full 3.4 m/s meant a sprinting carrier
		# knocked the ball 3.4 m/s beyond a speed they could not exceed --
		# it simply ran away from them. Measured in the isolated
		# close-control scene, the ball finished 8.5m clear of a sprinting
		# dribbler. The delta-v ceiling still bounds the impulse itself.
		var closing: float = clampf(gap / maxf(interval, 0.05), 0.0, TOUCH_MAX_CLOSING)
		var touch_speed: float = maxf(player_speed + closing, TOUCH_MIN_SPEED)
		touch_speed *= lerp(0.85, 1.0, stamina_ratio)
		# A heavy touch weakens the next contact rather than cancelling it.
		# Suppressing touches outright for control_loss_duration meant a
		# sharp turn at pace left the ball running on untouched until it was
		# outside the control radius: the carrier lost it on nearly every
		# turn (measured, possession held on 30 of 90 frames) and the ball
		# never followed the new direction at all. The old spring model kept
		# pulling at CONTROL_LOSS_STEER_SCALE through exactly this window;
		# the touch keeps the same idea.
		touch_speed *= control_quality
		var desired_vel: Vector3 = dribble_dir * touch_speed
		var delta_v: Vector3 = desired_vel - horizontal_vel
		# Cutting the ball across your body is a firmer contact than knocking
		# it along, and it has to be: redirecting a ball already rolling at
		# 7 m/s costs far more delta-v than nudging one that is drifting.
		# Capped at the ordinary touch strength, a 90-degree turn simply left
		# the ball running on in the old direction and out of control --
		# measured, the dribbler kept it on 2 of 60 frames through a turn.
		# Only a TURN gets the larger allowance: it has to cancel the ball's
		# existing momentum before it can redirect it, which no ordinary
		# touch does. A trailing ball is caught up by touching more OFTEN
		# (see the interval above), never harder -- letting it use the turn
		# allowance put a single touch at 4.0 m/s, which is exactly
		# PassEvaluator.PASS_SPEED_MIN, i.e. a touch indistinguishable from
		# a pass.
		delta_v = delta_v.limit_length(TOUCH_MAX_DELTA_V_TURN if turn_touch else TOUCH_MAX_DELTA_V)
		ball_body.apply_central_impulse(delta_v * ball_body.mass)
		_touch_timer = interval
		touched_ball_this_frame = true
		if turn_touch:
			time_since_turn_touch = 0.0
		_emit_touch(TouchKind.TURN if turn_touch else TouchKind.DRIBBLE,
			dribble_dir, delta_v.length(), ball_body)

	# Shepherding: sideways ONLY. This keeps the ball in the player's
	# corridor rather than letting it drift off the dribble line, but it
	# applies no force along the direction of travel, so it can never hold
	# the ball at a fixed distance the way the old spring did. Between
	# touches the ball is genuinely rolling free and decelerating under its
	# own friction, which is the gap that makes a dribble readable.
	# A player who is not going anywhere does not herd the ball anywhere
	# either -- the directional shepherding below is gated on intent, because
	# the sideways force alone accelerated a resting ball to 1.9 m/s whenever
	# it happened to sit off the player's facing axis (a stationary player
	# nudging the ball around on their own, caught by a regression test).
	#
	# They do still SETTLE it, though. This is damping only: it opposes the
	# ball's existing motion and can never create any, so a resting ball
	# stays resting, while a ball rolling at the feet of a carrier who has
	# just slowed down dies there instead of trundling away from them.
	# Without it, a carrier who slowed to a stop simply lost the ball --
	# nothing held it, the ball left the control radius, and because touches
	# require the ball to be inside that radius it could never be recovered.
	# Measured in the isolated AI-carrier scene: the carrier held the ball
	# for 33 of 240 frames and jogged on without it.
	if not has_dribble_intent:
		var settle: Vector3 = -horizontal_vel * SETTLE_DAMPING
		settle = settle.limit_length(SETTLE_ACCEL_CLAMP) * control_quality
		ball_body.apply_central_force(settle * ball_body.mass)
		return
	var lateral_vel: Vector3 = horizontal_vel - dribble_dir * horizontal_vel.dot(dribble_dir)
	var player_lateral: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
	player_lateral -= dribble_dir * player_lateral.dot(dribble_dir)
	# v0.9.0: TRIED A DEADBAND HERE AND REVERTED IT.
	#
	# The hypothesis was that this sideways spring-damper is what makes the
	# ball feel attached: it runs every frame with no deadband, and measured
	# over 180 frames of running the ball's lateral deviation from the
	# dribble line was min 0.00, mean 0.00, max 0.00. Zero to two decimals
	# looks exactly like a ball on rails.
	#
	# It is not. That zero is an artifact of the measurement: the isolated
	# scene runs a dead-straight line, the touch is applied exactly along
	# the dribble direction, and the ball starts on that line -- so nothing
	# ever pushes it off, with or without this force. Softening the gains
	# (7.0/3.2 -> 3.4/1.6) and adding a 0.35m corridor changed the straight
	# line not at all, and cost possession where the force is actually
	# load-bearing: through a 90-degree turn the carrier went from 120 of
	# 120 frames on the ball to 43, and stopping with the ball stopped
	# working altogether. Holding the ball through a direction change is
	# this force's real job.
	var shepherd: Vector3 = -lateral * SHEPHERD_ACCEL - (lateral_vel - player_lateral) * SHEPHERD_DAMPING
	shepherd = shepherd.limit_length(SHEPHERD_ACCEL_CLAMP) * control_quality * lerp(0.75, 1.0, stamina_ratio)
	ball_body.apply_central_force(shepherd * ball_body.mass)


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
## The ball this player is entitled to strike, or null.
##
## v0.8.8: passing and shooting now REQUIRE POSSESSION. This is the root
## cause of "the AI passes and shoots from unrealistic distances", and it
## was a missing check rather than a wrong number: execute_pass and
## execute_shot took the ball from `ball_in_action_range` -- the ActionArea,
## radius 2.5m -- and asked nothing else of it. Any player, human or AI,
## could strike a ball two and a half metres away that somebody else was
## dribbling. Measured over a 40s match before this: 64 kicks, up to 2.54m
## from the ball, and 14% of them struck by a player who was not the elected
## carrier at all.
##
## Possession is the licence to kick; the ActionArea is only about reach.
## The control-range ball is preferred because that is the one at this
## player's feet, with the action-range reference kept as a fallback for the
## frame or two where a touch has nudged the ball just outside the tighter
## sensor while POSSESSION_GRACE still holds -- action_area being a strict
## superset means this can only ever resolve to the same real ball.
func _kickable_ball() -> RigidBody3D:
	if not has_possession:
		return null
	# has_possession is per-player and two opponents can both hold it at
	# once; only ONE of them actually has the ball, and PossessionManager is
	# what decides which. Requiring that election closes the remaining gap
	# where the loser of a contest could still play the ball (measured at 6%
	# of kicks after the possession check alone). Falls back to the local
	# flag when there is no manager, which is only ever the case in isolated
	# unit tests.
	if possession_manager != null and possession_manager.current_carrier != self:
		return null
	# v0.8.8: BOUNDING this fallback was tried and REVERTED -- recorded so it
	# is not retried without the measurement that killed it.
	#
	# The concern is real on its face. The retain radius tops out at 1.90m
	# (dribble_distance_sprint * CONTROL_RADIUS_LEASH_MARGIN, plus up to 0.35
	# for defensive ability) while the ActionArea reaches 2.5m, so the band
	# between them is strikeable by whoever is the elected carrier. Measured
	# over a live match that is 1 kick in 39, at 2.40m against a 2.40m
	# challenge range -- on the line rather than past it, with the mean kick
	# struck from 0.99m.
	#
	# Bounding it at the control radius plus a ball diameter cost four
	# DETERMINISTIC assertions in v0_8_3's kick instrumentation: shots stopped
	# being recorded as shots at all, because a carrier who still legitimately
	# holds the ball under POSSESSION_GRACE -- precisely the case this
	# fallback exists for -- was left with nothing kickable and execute_shot
	# returned early. The touch model needs this fallback WIDER than the
	# sensor by construction, so bounding it against that sensor fights the
	# design. Trading "shots are recorded correctly" for a boundary case
	# sitting exactly on the limit is a bad trade.
	return ball_in_control_range if ball_in_control_range else ball_in_action_range


func execute_pass(min_alignment: float = PASS_ASSIST_MIN_ALIGNMENT, forward_axis: Vector3 = Vector3.ZERO, plan: TeamPlan = null) -> void:
	var ball: RigidBody3D = _kickable_ball()
	if ball == null:
		return
	var aim: Vector3 = _get_aim_direction()
	# A pass with a hard alignment cone is by definition one somebody aimed
	# -- that cone only ever comes from the human PASS button (the AI search
	# passes PASS_SEARCH_MIN_ALIGNMENT_OMNI). See W_ALIGNMENT_AIMED.
	var aimed: bool = min_alignment > PASS_SEARCH_MIN_ALIGNMENT_OMNI
	# v0.8.6: the human path now supplies a forward axis and the team plan
	# too. Without them W_PROGRESSION -- the single largest term in the
	# evaluation at 0.34 -- scored a flat zero on every human pass, because
	# _process_pass_input() called this with no arguments at all.
	var axis: Vector3 = forward_axis
	var effective_plan: TeamPlan = plan
	if effective_plan == null:
		effective_plan = team_plan
	if axis == Vector3.ZERO and effective_plan != null:
		axis = effective_plan.forward_axis()
	var trace: Array = []
	var option: PassEvaluator.Option = PassEvaluator.best_option(self, aim, axis, effective_plan, min_alignment, aimed, trace)
	if option == null:
		# Nothing worth playing to -- knock it into the aimed direction
		# rather than swallowing the input.
		#
		# v0.8.6: at a SHORT speed. This used to fire at PASS_SPEED_MAX
		# (11.0) scaled by pass_speed_scale (up to 1.1), i.e. 12.1 m/s
		# against a SHOT_SPEED_MIN of 12.5 -- a blind full-power punt
		# essentially indistinguishable from a shot, which is exactly the
		# reported "PASS often behaves like a weak shot or launches the
		# ball". A pass with no target is a knock into space, and should
		# look like one.
		last_kick_target = null
		var no_target_speed: float = PASS_NO_TARGET_SPEED * pass_speed_scale
		_emit_pass_trace(ball, aim, aimed, trace, null, aim, no_target_speed)
		_apply_kick_impulse(ball, no_target_speed, false, aim)
		return

	var to_point: Vector3 = option.aim_point - global_position
	to_point.y = 0.0
	var dir: Vector3 = to_point.normalized() if to_point.length() > 0.01 else aim
	# The AI search is omnidirectional and its "aim" is just whichever way it
	# happens to be running -- blending that in only ever drags the ball off
	# the teammate it deliberately chose. An aimed human pass keeps a trace
	# of the raw stick direction so a deliberate near-miss still reads as
	# the player's own, but only a trace: at the old 0.7 the ball landed
	# nearly a third of the way back toward wherever the stick pointed
	# rather than at the teammate the player was pointing AT.
	if aimed:
		dir = aim.slerp(dir, PASS_ASSIST_BLEND_AIMED).normalized()
	last_kick_target = option.target
	# v0.9.0: remember WHICH KIND of pass this was -- see
	# PassEvaluator.PassKind. Nothing in the simulation branches on it; it
	# exists so tests and diagnostics can tell a ball played into space from
	# one played to feet, and so a future animation or commentary layer has
	# the distinction available without re-deriving it.
	last_pass_kind = option.kind
	_emit_pass_trace(ball, aim, aimed, trace, option, dir, option.speed * pass_speed_scale)
	_apply_kick_impulse(ball, option.speed * pass_speed_scale, false, dir)


## v0.9.1: publish the whole pass chain as one record -- see `pass_attempted`.
##
## Called immediately BEFORE the impulse so the record can carry the requested
## launch speed, then completed one physics frame later with the ball's actual
## speed. The two are separate numbers on purpose: the brief asks whether the
## velocity the model asked for is the velocity the ball leaves with, and the
## only honest way to answer that is to measure the ball, not to restate the
## input.
func _emit_pass_trace(
	ball: RigidBody3D,
	aim: Vector3,
	aimed: bool,
	trace: Array,
	option: PassEvaluator.Option,
	kick_dir: Vector3,
	requested_speed: float
) -> void:
	if pass_attempted.get_connections().is_empty():
		return
	var kept := 0
	for c in trace:
		if c.get("kept", false):
			kept += 1
	var aim_n: Vector3 = aim.normalized() if aim.length() > 0.01 else Vector3.ZERO
	var info := {
		"passer": name,
		"team_id": team_id,
		"position": global_position,
		"aim": aim_n,
		"aimed": aimed,
		"candidates": trace,
		"considered": kept,
		"target": option.target if option != null else null,
		"target_name": option.target.name if option != null and option.target != null else "",
		"target_team_id": option.target.team_id if option != null and option.target != null else -1,
		"kind": option.kind if option != null else -1,
		"score": option.score if option != null else 0.0,
		"distance": option.distance if option != null else 0.0,
		"aim_point": option.aim_point if option != null else Vector3.ZERO,
		"kick_direction": kick_dir,
		"angular_error": rad_to_deg(aim_n.angle_to(kick_dir)) if aim_n != Vector3.ZERO else 0.0,
		"requested_speed": requested_speed,
		"actual_speed": 0.0,
	}
	pass_attempted.emit(info)
	_fill_actual_speed(ball, info)


func _fill_actual_speed(ball: RigidBody3D, info: Dictionary) -> void:
	await get_tree().physics_frame
	if is_instance_valid(ball):
		info["actual_speed"] = Vector2(ball.linear_velocity.x, ball.linear_velocity.z).length()


## v0.9.1: one place that says "this player's relationship with the ball just
## changed", for a settle-the-ball or lost-it reaction clip. Every site that
## flips has_possession routes through here rather than each growing its own
## emit, so the signal cannot drift out of step with the flag.
## How fast the ball is moving RELATIVE to this player, on the ground plane.
##
## The number that decides whether a ball is being carried or is arriving:
## a carrier sprinting at 7 m/s with the ball running ahead of them at the
## same pace has a relative speed near zero, while the same 7 m/s ball at a
## standing keeper is an arriving ball.
func _relative_ball_speed(ball: RigidBody3D) -> float:
	return Vector2(
		ball.linear_velocity.x - velocity.x,
		ball.linear_velocity.z - velocity.z).length()


func _emit_possession_changed(what: String, reason: String = "") -> void:
	if possession_changed.get_connections().is_empty():
		return
	possession_changed.emit({
		"kind": what,
		"reason": reason,
		"position": global_position,
		"velocity": velocity,
		"possession_time": possession_time,
	})


## `aim_dir_override` is how an AI shot says WHERE it is shooting. Without
## it the kick falls back to _get_aim_direction(), which is move_input --
## and move_input is Vector2.ZERO for any carrier already inside their
## arrive radius, so the shot went wherever _facing_angle last happened to
## point. The human's charge-release path deliberately keeps the default:
## for them, "where I am facing/aiming" is the intent.
func execute_shot(charge_ratio: float, aim_dir_override: Vector3 = Vector3.ZERO) -> void:
	var ball: RigidBody3D = _kickable_ball()
	if ball == null:
		return
	var speed: float = lerp(shoot_min_speed, shoot_max_speed, clampf(charge_ratio, 0.0, 1.0))
	last_kick_target = null
	_apply_kick_impulse(ball, speed, true, aim_dir_override)


## How hard to strike a shot that has to travel `distance` metres.
##
## v0.8.6. The AI previously derived its shot power from "range quality",
## which is highest when the shooter is CLOSEST to goal -- so it hit the
## ball hardest from point-blank range and softest from the edge of its own
## shooting range, the opposite of how shooting works and the direct cause
## of "their shots are still too weak" (the shots being complained about are
## the long ones). Power now rises with distance, floored well above nothing
## so even a tap-in is struck rather than rolled.
##
## Returns a 0..1 charge ratio, so it stays inside the shot speed band and a
## shot can never be confused with a pass no matter what is passed in.
func shot_charge_for_distance(distance: float) -> float:
	return clampf(SHOT_CHARGE_MIN + distance / SHOT_CHARGE_FULL_DISTANCE, SHOT_CHARGE_MIN, 1.0)


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
	var option: PassEvaluator.Option = PassEvaluator.best_option(self, base_dir, forward_axis, null, min_alignment)
	return option.target if option != null else null


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


## `speed` is the intended launch speed of the ball in m/s (see the Pass /
## Shoot block above). Converting to an impulse here, at the one place that
## actually has the ball, keeps every caller working in units a human can
## reason about and makes the shot/pass bands directly comparable.
func _apply_kick_impulse(ball: RigidBody3D, speed: float, is_shot: bool, aim_dir_override: Vector3 = Vector3.ZERO) -> void:
	var aim_dir: Vector3 = aim_dir_override if aim_dir_override != Vector3.ZERO else _get_aim_direction()
	aim_dir = aim_dir.normalized()
	# Running onto the ball adds pace, but only ALONG the aim. Adding the
	# whole velocity vector (as before v0.8.3) rotated every kick away from
	# where it was aimed by up to the player's full speed -- for a pass that
	# means missing the teammate the evaluator just carefully chose.
	var launch_speed: float = speed + maxf(0.0, velocity.dot(aim_dir)) * momentum_transfer
	# v0.8.7: REPLACE the ball's horizontal velocity rather than adding to
	# it, so the ball actually leaves at launch_speed.
	#
	# The old impulse was added on top of whatever the ball was already
	# doing. That was survivable while close control kept the ball pinned
	# and barely moving, but a touch-dribbled ball now travels with the
	# carrier, so a pass inherited that pace on top of its own: measured, a
	# pass left the boot at 13.1 m/s against a shot floor of 12.5, i.e. the
	# pass/shot bands -- which a test asserts cannot overlap, and which the
	# brief requires to stay clearly different -- had started to cross.
	# Momentum from running onto the ball is already accounted for above,
	# deliberately and only along the aim.
	# v0.9.1: the wind-up hook. The simulation strikes the ball on the same
	# frame the intent is formed -- there is no anticipation phase in the
	# physics, and adding one would change gameplay timing, which this
	# milestone explicitly must not do. So this fires here, one call ahead of
	# the contact, and an animation layer that wants lead time takes it from
	# here while ball_touched drives the actual foot plant.
	if not action_started.get_connections().is_empty():
		action_started.emit({
			"kind": TouchKind.SHOT if is_shot else TouchKind.PASS,
			"direction": aim_dir,
			"strength": launch_speed,
			"target": last_kick_target,
			"position": global_position,
		})

	var current_horizontal := Vector3(ball.linear_velocity.x, 0.0, ball.linear_velocity.z)
	var delta_v: Vector3 = aim_dir * launch_speed - current_horizontal
	# A pass is a GROUND pass -- it stays on the deck, which is both what a
	# pass looks like and what keeps PassEvaluator's distance solve (fitted
	# to a rolling ball) applicable to it.
	delta_v.y = kick_lift if is_shot else PASS_LIFT

	# v0.9.1.1: the ball leaves from the player's feet, i.e. from INSIDE
	# their capsule, and the ball collides with players again. Without this
	# the shot rebounds off the shooter. See BallController.pass_through_for.
	if ball is BallController:
		ball.pass_through_for(self)

	ball.apply_central_impulse(delta_v * ball.mass)

	last_kick_kind = KickKind.SHOT if is_shot else KickKind.PASS
	last_kick_power = launch_speed
	last_kick_dir = aim_dir
	kick_count += 1
	# A pass and a shot are ball contacts like any other -- see the
	# `ball_touched` signal. Emitted through the same channel as a dribble
	# touch so an animation layer has ONE place to hook, rather than one
	# hook for close control and another for kicking.
	_emit_touch(TouchKind.SHOT if is_shot else TouchKind.PASS,
		aim_dir, delta_v.length(), ball)
	post_action_kind = last_kick_kind
	post_action_timer = POST_ACTION_WINDOW

	# v0.9.1: playing the ball is the commonest way to stop having it, so the
	# possession event has to fire here as well as on the two paths in
	# _update_possession. The reason distinguishes it: an animation layer
	# wants a settle-or-react clip when the ball is TAKEN, and nothing extra
	# when the player deliberately played it -- the kick's own
	# action_started/action_released already own that moment.
	if has_possession:
		_emit_possession_changed("lost", "kicked")
	has_possession = false
	_control_lost_timer = 0.0
	_possession_cooldown_timer = possession_release_cooldown
	time_since_last_touch = 0.0

	if is_shot:
		_pending_shot_check_timer = _SHOT_MISS_CHECK_DELAY

	# v0.9.1: the follow-through hook. The ball has left; from here the body
	# is on its own and a clip can blend back to locomotion.
	if not action_released.get_connections().is_empty():
		action_released.emit({
			"kind": TouchKind.SHOT if is_shot else TouchKind.PASS,
			"direction": aim_dir,
			"strength": launch_speed,
			"target": last_kick_target,
			"position": global_position,
		})

	if animation_controller:
		animation_controller.play_action("shoot" if is_shot else "pass")


func _on_action_area_entered(body: Node3D) -> void:
	if body is RigidBody3D and body.is_in_group("ball"):
		ball_in_action_range = body
		_known_ball = body


func _on_action_area_exited(body: Node3D) -> void:
	if body == ball_in_action_range:
		ball_in_action_range = null


func _on_control_area_entered(body: Node3D) -> void:
	if body is RigidBody3D and body.is_in_group("ball"):
		ball_in_control_range = body
		_known_ball = body


## Only drops the ball reference -- whether that actually ends possession
## is _update_possession's call alone (it applies POSSESSION_GRACE first),
## so there is exactly one place that clears has_possession. Clearing it
## here too would defeat the grace, since the ball crossing the control
## radius is precisely the event the grace exists to absorb.
func _on_control_area_exited(body: Node3D) -> void:
	if body == ball_in_control_range:
		ball_in_control_range = null
