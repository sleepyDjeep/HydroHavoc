class_name GameHUD
extends CanvasLayer

## Responsive UI for HydroHavoc supporting dual 16:9 Landscape and 9:16 Vertical TikTok layouts.

signal ability_triggered(ability_id: int)
signal simulate_event_clicked(event_type: String)
signal toggle_aspect_ratio_requested()

@onready var score_label: Label = $RootControl/TopBar/ScoreBox/ScoreVal
@onready var multiplier_label: Label = $RootControl/TopBar/ScoreBox/MultiplierVal
@onready var water_vol_bar: ProgressBar = $RootControl/TopBar/StatsBox/WaterVolBar
@onready var water_vol_label: Label = $RootControl/TopBar/StatsBox/WaterVolLabel
@onready var drain_bar: ProgressBar = $RootControl/TopBar/DrainBox/DrainBar
@onready var drain_label: Label = $RootControl/TopBar/DrainBox/DrainLabel
@onready var queue_container: HBoxContainer = $RootControl/RightPanel/QueueContainer
@onready var vip_label: Label = $RootControl/VipBanner/VipLabel
@onready var toast_panel: PanelContainer = $RootControl/ToastPanel
@onready var toast_title: Label = $RootControl/ToastPanel/VBox/ToastTitle
@onready var toast_subtitle: Label = $RootControl/ToastPanel/VBox/ToastSubtitle
@onready var btn_ability_1: Button = $RootControl/BottomBar/BtnAbility1
@onready var btn_ability_2: Button = $RootControl/BottomBar/BtnAbility2
@onready var btn_ability_3: Button = $RootControl/BottomBar/BtnAbility3

const ABILITY_LABELS: Array[String] = ["[1] Flash Freeze", "[2] Solar Ray", "[3] Seismic Anchor"]

var is_vertical_mode: bool = false
var toast_timer: float = 0.0

func _ready() -> void:
	toast_panel.visible = false
	_setup_theme_styling()

func _process(delta: float) -> void:
	if toast_timer > 0.0:
		toast_timer -= delta
		if toast_timer <= 0.0:
			var tween: Tween = create_tween()
			tween.tween_property(toast_panel, "modulate:a", 0.0, 0.35)
			tween.tween_callback(func(): toast_panel.visible = false)

func update_score(score: int, multiplier: float) -> void:
	score_label.text = str(score)
	multiplier_label.text = "x" + str(snappedf(multiplier, 0.1)) + " COMBO"

func update_water_stats(active_vol: float, max_vol: float) -> void:
	var safe_max: float = maxf(max_vol, 1.0)
	water_vol_bar.max_value = safe_max
	water_vol_bar.value = clampf(active_vol, 0.0, safe_max)
	water_vol_label.text = str(int(active_vol)) + " L / " + str(int(safe_max)) + " L"

func update_drain_meter(spilled: float, threshold: float) -> void:
	drain_bar.max_value = threshold
	drain_bar.value = spilled
	var pct: float = clampf(spilled / maxf(threshold, 1.0), 0.0, 1.0)
	drain_label.text = str(int(pct * 100.0)) + "% Spilled"

	if pct > 0.8:
		drain_bar.modulate = Color(1.0, 0.15, 0.15)
	elif pct > 0.5:
		drain_bar.modulate = Color(1.0, 0.85, 0.2)
	else:
		drain_bar.modulate = Color(0.2, 0.9, 0.4)

func update_vip(donor: String, amount: int) -> void:
	vip_label.text = "MVP Gifter: " + donor + " (" + str(amount) + " pts)"

func update_ability_cooldowns(cooldowns: Array[float]) -> void:
	var buttons: Array[Button] = [btn_ability_1, btn_ability_2, btn_ability_3]
	for i in range(buttons.size()):
		var btn: Button = buttons[i]
		var cd: float = cooldowns[i] if i < cooldowns.size() else 0.0
		var label: String = ABILITY_LABELS[i]
		if cd > 0.0:
			label += "  (" + str(snappedf(cd, 0.1)) + "s)"
		if btn.text != label:
			btn.text = label
		btn.disabled = cd > 0.0

func show_alert(title: String, subtitle: String, color: Color) -> void:
	toast_title.text = title
	toast_subtitle.text = subtitle
	toast_panel.modulate = color
	toast_panel.visible = true
	toast_panel.modulate.a = 1.0
	toast_timer = 3.2

	# Juiced punch scale animation
	toast_panel.scale = Vector2(0.85, 0.85)
	var tw: Tween = create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(toast_panel, "scale", Vector2.ONE, 0.25)

func update_queue_display(queue_pieces: Array[PieceManager.PieceData]) -> void:
	for child in queue_container.get_children():
		child.queue_free()

	for piece in queue_pieces:
		var card: PanelContainer = PanelContainer.new()
		card.custom_minimum_size = Vector2(80, 80)
		var style: StyleBoxFlat = StyleBoxFlat.new()
		style.bg_color = Color(0.1, 0.14, 0.2, 0.9)
		style.border_color = piece.color
		style.set_border_width_all(2)
		style.set_corner_radius_all(8)
		card.add_theme_stylebox_override("panel", style)

		var lbl: Label = Label.new()
		lbl.text = piece.name
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		lbl.modulate = piece.color
		card.add_child(lbl)
		queue_container.add_child(card)

func toggle_orientation() -> void:
	is_vertical_mode = not is_vertical_mode
	emit_signal("toggle_aspect_ratio_requested")

func _setup_theme_styling() -> void:
	pass
