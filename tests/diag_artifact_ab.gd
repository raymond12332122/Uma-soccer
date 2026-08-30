extends Node3D

## v0.9.2.1: prove the artifact fix, as a controlled A/B (brief section 1).
##
## Comparing a screenshot from one run against a screenshot from another run
## is not evidence -- the matches diverge, the camera is somewhere else, and
## the numbers move for reasons that have nothing to do with the change. A
## first attempt at exactly that showed no difference in the measured dark
## fraction while the two frames looked obviously different, which is the
## signal that the comparison, not the fix, was wrong.
##
## So this runs the SAME match twice in one process, from the same seed, with
## the same scripted camera path, once with the v0.9.2 render bounds and once
## with the corrected ones, and compares the frames pairwise.
##
## The measure is the fraction of the frame below a luminance of 0.20. The
## artifact is a dark BLUE-black (rgb 0.024/0.071/0.129, luminance 0.065)
## against a pitch at luminance 0.47, so a per-channel "dark everywhere" test
## misses it on the blue channel alone -- which is how the first metric came
## back flat.
##
## Run windowed:
##   DISPLAY=:88 XDG_RUNTIME_DIR=/tmp/xdgrun LIBGL_ALWAYS_SOFTWARE=1 \
##     godot --path . --rendering-driver opengl3 --display-driver x11 \
##     tests/DiagArtifactAB.tscn

const MainScene := preload("res://scenes/Main.tscn")
const SHOT_DIR := "user://v0921_ab"
const SEED := 20250929
const SETTLE := 90
const SAMPLES := 10
## Physics frames between captures.
const GAP := 20
const STEP := 4


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	print("ARTIFACT-AB: ==== same seeded match, bounds OFF then ON ====")

	AnimationController.force_legacy_bounds = true
	var before: Array = await _run("legacy")
	AnimationController.force_legacy_bounds = false
	var after: Array = await _run("fixed")

	print("ARTIFACT-AB: frame |  legacy |   fixed |  change")
	var sum_b := 0.0
	var sum_a := 0.0
	var worst_delta := 0.0
	var worst_i := -1
	for i in range(mini(before.size(), after.size())):
		var b: float = before[i]
		var a: float = after[i]
		sum_b += b
		sum_a += a
		if b - a > worst_delta:
			worst_delta = b - a
			worst_i = i
		print("ARTIFACT-AB:  %4d | %7.4f | %7.4f | %+7.4f" % [i, b, a, a - b])
	var n: int = mini(before.size(), after.size())
	if n > 0:
		print("ARTIFACT-AB: MEAN dark fraction  legacy %.4f  fixed %.4f  (%.0f%% less)" % [
			sum_b / n, sum_a / n, 100.0 * (sum_b - sum_a) / maxf(sum_b, 0.0001)])
		print("ARTIFACT-AB: biggest single-frame improvement %.4f at sample %d" % [
			worst_delta, worst_i])
	get_tree().quit()


func _run(label: String) -> Array:
	seed(SEED)
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(SETTLE):
		await get_tree().physics_frame

	var out: Array = []
	for s in range(SAMPLES):
		for f in range(GAP):
			await get_tree().physics_frame
		await RenderingServer.frame_post_draw
		var img: Image = get_viewport().get_texture().get_image()
		out.append(_dark_fraction(img))
		if s in [6, 12, 18]:
			img.save_png(ProjectSettings.globalize_path(
				"%s/%s_%02d.png" % [SHOT_DIR, label, s]))
	print("ARTIFACT-AB: %s captured %d samples" % [label, out.size()])
	main.queue_free()
	await get_tree().physics_frame
	return out


func _dark_fraction(img: Image) -> float:
	var dark := 0
	var total := 0
	for y in range(0, img.get_height(), STEP):
		for x in range(0, img.get_width(), STEP):
			total += 1
			var c: Color = img.get_pixel(x, y)
			if 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b < 0.20:
				dark += 1
	return float(dark) / maxf(total, 1)
