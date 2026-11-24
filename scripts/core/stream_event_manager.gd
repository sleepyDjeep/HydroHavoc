class_name StreamEventManager
extends Node

## Central Hub for Twitch EventSub, TikTok Live Gifts, and Mock Event Testing.
## Dispatches crowd-funded hazards and blessings directly into the physics simulation.

signal stream_action_received(donor: String, action_type: String, value: int, platform: String)
signal alert_announcement(title: String, subtitle: String, color: Color)

enum CrowdAction {
	DUCK_SPLASH,    # Small water splash (TikTok Rose / 10 Bits)
	WALL_BLESSING,  # Reinforces walls (TikTok Heart / 50 Bits)
	WATER_BOMB,     # Dropping heavy water payload (TikTok Doughnut / 100 Bits)
	TSUNAMI,        # Full-width tidal wave across arena (TikTok Galaxy / 500 Bits)
	VOLCANO_BOMB,   # Cratering earthquake blast (TikTok Lion / 1000 Bits)
	FLASH_FREEZE,   # Freezes lakes for 8s (Sub / Tier 2 gift)
	SPONGE_RESCUE   # Giant sponge soaks up threatening spill (Channel Points / 250 Bits)
}

# Top Donors tracking for the VIP Podium / Throne
var top_donors: Dictionary = {}
var highest_single_donor: String = "No VIP Yet"
var highest_single_amount: int = 0

func _ready() -> void:
	pass

func simulate_twitch_event(donor_name: String, bits: int) -> void:
	# Applied at the ingress point so alerts and the VIP throne get the same treatment
	# as the nameplates, and so a future bridge inherits it without changes.
	donor_name = NamePolicy.display_name(donor_name)
	_record_donor(donor_name, bits)
	if bits < 50:
		emit_signal("stream_action_received", donor_name, "DUCK_SPLASH", bits, "Twitch")
		emit_signal("alert_announcement", donor_name + " sent " + str(bits) + " Bits!", "Rubber Duck Splash Dropped!", Color(0.2, 0.8, 1.0))
	elif bits < 200:
		emit_signal("stream_action_received", donor_name, "WATER_BOMB", bits, "Twitch")
		emit_signal("alert_announcement", donor_name + " dropped a WATER BOMB!", str(bits) + " Bits! Watch out!", Color(0.1, 0.5, 1.0))
	elif bits < 500:
		emit_signal("stream_action_received", donor_name, "SPONGE_RESCUE", bits, "Twitch")
		emit_signal("alert_announcement", donor_name + " sent a SPONGE RESCUE!", "Massive lake soak!", Color(0.9, 0.8, 0.1))
	elif bits < 1000:
		emit_signal("stream_action_received", donor_name, "TSUNAMI", bits, "Twitch")
		emit_signal("alert_announcement", "TSUNAMI ALERT!", donor_name + " sent " + str(bits) + " Bits!", Color(0.9, 0.2, 0.2))
	else:
		emit_signal("stream_action_received", donor_name, "VOLCANO_BOMB", bits, "Twitch")
		emit_signal("alert_announcement", "APOCALYPSE BOMB!", donor_name + " summoned a Meteor!", Color(1.0, 0.1, 0.3))

func simulate_tiktok_gift(donor_name: String, gift_name: String, coin_value: int) -> void:
	donor_name = NamePolicy.display_name(donor_name)
	_record_donor(donor_name, coin_value)
	match gift_name.to_lower():
		"rose":
			emit_signal("stream_action_received", donor_name, "DUCK_SPLASH", coin_value, "TikTok")
			emit_signal("alert_announcement", donor_name + " sent a Rose!", "Mini Splash!", Color(1.0, 0.4, 0.6))
		"ice cream":
			emit_signal("stream_action_received", donor_name, "WALL_BLESSING", coin_value, "TikTok")
			emit_signal("alert_announcement", donor_name + " sent Ice Cream!", "Wall Boost!", Color(0.3, 0.9, 0.4))
		"doughnut":
			emit_signal("stream_action_received", donor_name, "WATER_BOMB", coin_value, "TikTok")
			emit_signal("alert_announcement", donor_name + " sent a Doughnut!", "Water Payload Inbound!", Color(0.1, 0.6, 1.0))
		"galaxy":
			emit_signal("stream_action_received", donor_name, "TSUNAMI", coin_value, "TikTok")
			emit_signal("alert_announcement", "GALAXY TSUNAMI!", donor_name + " flooded the grid!", Color(0.6, 0.2, 1.0))
		"lion", "universe":
			emit_signal("stream_action_received", donor_name, "VOLCANO_BOMB", coin_value, "TikTok")
			emit_signal("alert_announcement", "LION ROAR BLAST!", donor_name + " cracked the earth!", Color(1.0, 0.6, 0.0))
		_:
			emit_signal("stream_action_received", donor_name, "WATER_BOMB", coin_value, "TikTok")
			emit_signal("alert_announcement", donor_name + " sent " + gift_name, "Incoming Hazard!", Color(0.9, 0.5, 0.2))

func _record_donor(donor_name: String, amount: int) -> void:
	if not top_donors.has(donor_name):
		top_donors[donor_name] = 0
	top_donors[donor_name] += amount

	if top_donors[donor_name] > highest_single_amount:
		highest_single_amount = top_donors[donor_name]
		highest_single_donor = donor_name
