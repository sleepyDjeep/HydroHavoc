extends SceneTree

## Seeded, scripted simulation harness. Boots the real scene, drives a fixed sequence of
## piece drops, gifts and abilities through GameManager, and asserts over the whole run:
##
##   1. water mass conservation  — added - evaporated - spilled == active volume
##   2. no non-finite values     — water, terrain, fluxes, totals, prop positions
##   3. no orphaned props        — nothing tracked that is dead/plunged/queued for free,
##                                 nothing untracked that is still a live floating prop
##   4. the fixed-step catch-up cap holds under a frame spike, and does not leave a
##      backlog that would keep the sim in debt
##
## Run by tools/check.sh (and therefore CI). Exit code is the failure count's fault:
## non-zero on any failed check.

const SEED: int = 20261124
const DT: float = 1.0 / 30.0
const TICKS: int = 240
const GIFT_NAMES: Array[String] = ["rose", "doughnut", "galaxy", "lion"]
const MASS_EPSILON: float = 0.10

var checks: int = 0
var failures: int = 0

var fields_ok: bool = true
var fields_detail: String = ""
var max_mass_drift: float = 0.0
var max_mass_drift_tick: int = -1
var props_ok: bool = true
var props_detail: String = ""
var peak_props: int = 0

func _initialize() -> void:
	seed(SEED) # deterministic by construction: same seed, same script, same numbers
	_run()

func _ok(condition: bool, label: String, detail: String = "") -> void:
	checks += 1
	if condition:
		return
	failures += 1
	print("FAIL " + label + ("" if detail.is_empty() else "  (" + detail + ")"))

func _finite(value: float) -> bool:
	return not (is_nan(value) or is_inf(value))

func _run() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	if scene == null:
		print("FAIL could not load res://scenes/main.tscn")
		quit(1)
		return

	var main: Node = scene.instantiate()
	root.add_child(main)
	await process_frame

	var sim: FluidSim = main.sim
	var pm: PropManager = main.get_node("Arena/PropManager")
	main.set_process(false) # the harness owns the clock

	for tick in range(TICKS):
		if tick % 18 == 0:
			main.call("_apply_current_piece")
		if tick % 40 == 10:
			main.stream_events.simulate_tiktok_gift(
				"viewer_" + str(tick), GIFT_NAMES[int(tick / 40.0) % GIFT_NAMES.size()], 100)
		if tick % 60 == 30:
			main.call("_on_ability_triggered", 2) # solar ray: water -> steam
		if tick % 75 == 5:
			main.call("_on_ability_triggered", 3) # seismic anchor: raises terrain

		main.call("_process", DT)

		_check_fields(sim, tick)
		_check_mass(sim, tick)
		_check_props(pm, tick)

	_ok(fields_ok, "field values stay finite", fields_detail)
	_ok(max_mass_drift <= MASS_EPSILON, "water mass conserved over %d ticks" % TICKS,
		"max drift %.5f at tick %d (limit %.2f)" % [max_mass_drift, max_mass_drift_tick, MASS_EPSILON])
	_ok(props_ok, "prop bookkeeping has no orphans", props_detail)

	_check_catch_up(main, sim)

	print("mass: added %.2f = active %.2f + evap %.2f + drained %.2f, drift %.6f" %
		[sim.total_added_water, sim.active_water_volume, sim.total_evaporated_water,
		sim.total_drained_water, max_mass_drift])
	print("props: peak tracked %d, still floating %d, score %d" %
		[peak_props, pm.active_props.size(), main.score])
	print("--- %d checks, %d failures ---" % [checks, failures])
	quit(1 if failures > 0 else 0)

func _check_fields(sim: FluidSim, tick: int) -> void:
	for i in range(FluidSim.CELL_COUNT):
		var bad: String = ""
		if not _finite(sim.water[i]) or not _finite(sim.terrain[i]):
			bad = "water/terrain at cell %d" % i
		elif not _finite(sim.flux_n[i]) or not _finite(sim.flux_s[i]) \
				or not _finite(sim.flux_e[i]) or not _finite(sim.flux_w[i]):
			bad = "flux at cell %d" % i
		if not bad.is_empty():
			if fields_ok:
				fields_ok = false
				fields_detail = "tick %d: %s" % [tick, bad]
			break

	if not _finite(sim.active_water_volume) or not _finite(sim.total_spilled_water) \
			or not _finite(sim.total_added_water) or not _finite(sim.total_evaporated_water):
		if fields_ok:
			fields_ok = false
			fields_detail = "tick %d: non-finite volume total" % tick

func _check_mass(sim: FluidSim, tick: int) -> void:
	# total_drained, not total_spilled_water: the earthquake zeroes the drain meter every
	# 35 L, which would otherwise show up here as 35 L of vanished water.
	var expected: float = sim.total_added_water - sim.total_evaporated_water - sim.total_drained_water
	var drift: float = absf(expected - sim.active_water_volume)
	if drift > max_mass_drift:
		max_mass_drift = drift
		max_mass_drift_tick = tick

func _check_props(pm: PropManager, _tick: int) -> void:
	peak_props = maxi(peak_props, pm.active_props.size())

	for prop in pm.active_props:
		if not is_instance_valid(prop):
			props_ok = false
			props_detail = "dead instance still tracked at tick %d" % _tick
			continue
		if prop.is_queued_for_deletion():
			props_ok = false
			props_detail = "tracked prop is queued for deletion at tick %d" % _tick
		if prop.has_plunged:
			props_ok = false
			props_detail = "plunged prop not removed from tracking at tick %d" % _tick
		if not _finite(prop.position.x) or not _finite(prop.position.y) or not _finite(prop.position.z):
			props_ok = false
			props_detail = "non-finite prop position at tick %d" % _tick
		if pm.active_props.count(prop) != 1:
			props_ok = false
			props_detail = "prop tracked more than once at tick %d" % _tick

	for child in pm.get_children():
		if child is FloatingProp and not pm.active_props.has(child) and not child.has_plunged:
			props_ok = false
			props_detail = "live prop missing from tracking at tick %d" % _tick

func _check_catch_up(main: Node, sim: FluidSim) -> void:
	# One 0.5 s frame would otherwise ask for 15 fixed steps.
	main.sim_accum = 0.0
	main.call("_process", 0.5)
	_ok(main.sim_steps_last_frame <= GameManager.MAX_SIM_STEPS_PER_FRAME,
		"frame spike is capped", "%d steps (cap %d)" %
		[main.sim_steps_last_frame, GameManager.MAX_SIM_STEPS_PER_FRAME])
	# Measured against the uncapped demand (15 steps) rather than against the cap itself,
	# so removing or raising the cap past what a 0.5 s frame needs fails here too.
	var uncapped_steps: int = int(0.5 / GameManager.TICK_RATE)
	_ok(main.sim_steps_last_frame < uncapped_steps, "cap is the binding limit",
		"%d of %d possible steps" % [main.sim_steps_last_frame, uncapped_steps])
	_ok(main.sim_accum <= GameManager.TICK_RATE + 0.0001,
		"spike leaves no catch-up backlog", "accumulator %.4f s (tick %.4f s)" %
		[main.sim_accum, GameManager.TICK_RATE])

	# And a normal frame is still exactly one step.
	main.sim_accum = 0.0
	var before: float = sim.active_water_volume
	main.call("_process", DT)
	_ok(main.sim_steps_last_frame == 1, "30 Hz frame steps once",
		"%d steps" % main.sim_steps_last_frame)
	_ok(_finite(sim.active_water_volume), "volume stays finite after the spike test",
		"%.2f -> %.2f" % [before, sim.active_water_volume])
