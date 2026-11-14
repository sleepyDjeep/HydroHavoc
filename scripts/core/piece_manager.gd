class_name PieceManager
extends RefCounted

## Manages falling polyominoes, hazard pieces, piece queue, and rotations.

enum PieceType {
	UPPER,       # Wall builder (raises terrain)
	DOWNER,      # Terrain digger (lowers terrain)
	WATER_DROP,  # Liquid downpour
	FIREBALL,    # Evaporates water into steam
	BOMB,        # Blasts craters
	SPONGE       # Soaks up liquid
}

class PieceData:
	var type: PieceType
	var cells: Array[Vector2i] = [] # Local grid offsets from anchor (0,0)
	var color: Color
	var name: String
	var power: float = 1.0

	func _init(p_type: PieceType, p_name: String, p_cells: Array[Vector2i], p_color: Color, p_power: float = 1.0):
		type = p_type
		name = p_name
		cells = p_cells
		color = p_color
		power = p_power

	func get_rotated(rotation_step: int) -> Array[Vector2i]:
		var rot: int = posmod(rotation_step, 4)
		if rot == 0:
			return cells

		var rotated: Array[Vector2i] = []
		for c in cells:
			match rot:
				1: # 90 deg clockwise (x, y) -> (-y, x)
					rotated.append(Vector2i(-c.y, c.x))
				2: # 180 deg (x, y) -> (-x, -y)
					rotated.append(Vector2i(-c.x, -c.y))
				3: # 270 deg (x, y) -> (y, -x)
					rotated.append(Vector2i(c.y, -c.x))
		return rotated

var current_piece: PieceData
var queue: Array[PieceData] = []
var rotation_step: int = 0
const QUEUE_SIZE: int = 4

# Template library of classic Wetrix shapes
var templates: Array[Dictionary] = [
	# Uppers (Walls)
	{"type": PieceType.UPPER, "name": "Wall 2x1", "cells": [Vector2i(0,0), Vector2i(1,0)], "color": Color(0.2, 0.85, 0.3), "power": 1.0},
	{"type": PieceType.UPPER, "name": "Wall 3x1", "cells": [Vector2i(-1,0), Vector2i(0,0), Vector2i(1,0)], "color": Color(0.2, 0.85, 0.3), "power": 1.0},
	{"type": PieceType.UPPER, "name": "Corner L", "cells": [Vector2i(0,0), Vector2i(1,0), Vector2i(0,1)], "color": Color(0.3, 0.9, 0.4), "power": 1.0},
	{"type": PieceType.UPPER, "name": "Block 2x2", "cells": [Vector2i(0,0), Vector2i(1,0), Vector2i(0,1), Vector2i(1,1)], "color": Color(0.15, 0.75, 0.25), "power": 1.0},
	{"type": PieceType.UPPER, "name": "Pillar 1x1", "cells": [Vector2i(0,0)], "color": Color(0.4, 0.95, 0.5), "power": 1.5},

	# Water Drops
	{"type": PieceType.WATER_DROP, "name": "Water Drop", "cells": [Vector2i(0,0), Vector2i(1,0), Vector2i(0,1), Vector2i(1,1)], "color": Color(0.0, 0.7, 1.0), "power": 2.5},
	{"type": PieceType.WATER_DROP, "name": "Rain Burst", "cells": [Vector2i(0,0), Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)], "color": Color(0.2, 0.8, 1.0), "power": 3.0},

	# Fireball (Vaporizer)
	{"type": PieceType.FIREBALL, "name": "Fireball", "cells": [Vector2i(0,0), Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)], "color": Color(1.0, 0.35, 0.1), "power": 4.0},

	# Downer
	{"type": PieceType.DOWNER, "name": "Downer Trench", "cells": [Vector2i(0,0), Vector2i(1,0)], "color": Color(0.7, 0.4, 0.2), "power": -1.0},

	# Bomb
	{"type": PieceType.BOMB, "name": "Bomb", "cells": [Vector2i(0,0)], "color": Color(0.9, 0.1, 0.2), "power": 2.5},

	# Sponge
	{"type": PieceType.SPONGE, "name": "Sponge", "cells": [Vector2i(0,0), Vector2i(1,0), Vector2i(0,1), Vector2i(1,1)], "color": Color(0.95, 0.85, 0.2), "power": 3.0}
]

func _init() -> void:
	for i in range(QUEUE_SIZE):
		queue.append(_generate_random_piece())
	advance_queue()

func advance_queue() -> PieceData:
	rotation_step = 0
	current_piece = queue.pop_front()
	queue.append(_generate_random_piece())
	return current_piece

func rotate_clockwise() -> void:
	rotation_step = (rotation_step + 1) % 4

func rotate_counter_clockwise() -> void:
	rotation_step = (rotation_step + 3) % 4

func get_current_cells() -> Array[Vector2i]:
	if not current_piece:
		return []
	return current_piece.get_rotated(rotation_step)

func _generate_random_piece() -> PieceData:
	# Weighted piece selection: 40% Uppers, 30% Water, 15% Fireball, 8% Downer, 4% Bomb, 3% Sponge
	var roll: float = randf()
	var filtered: Array[Dictionary] = []

	if roll < 0.42:
		filtered = templates.filter(func(t): return t.type == PieceType.UPPER)
	elif roll < 0.72:
		filtered = templates.filter(func(t): return t.type == PieceType.WATER_DROP)
	elif roll < 0.86:
		filtered = templates.filter(func(t): return t.type == PieceType.FIREBALL)
	elif roll < 0.93:
		filtered = templates.filter(func(t): return t.type == PieceType.DOWNER)
	elif roll < 0.97:
		filtered = templates.filter(func(t): return t.type == PieceType.BOMB)
	else:
		filtered = templates.filter(func(t): return t.type == PieceType.SPONGE)

	var chosen: Dictionary = filtered.pick_random()
	var cells_copy: Array[Vector2i] = []
	for c in chosen.cells:
		cells_copy.append(c)

	return PieceData.new(chosen.type, chosen.name, cells_copy, chosen.color, chosen.power)
