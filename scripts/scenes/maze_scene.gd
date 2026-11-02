extends Control
## M3 迷宫「废弃军事基地」：格子移动 + 迷宫遭遇 + 终点赏金首 + 角落隐藏引擎。
## 布局来自 data/maze.json，规则在 maze_rules.gd / world_rules.gd。

const MRules := preload("res://scripts/world/maze_rules.gd")
const WRules := preload("res://scripts/world/world_rules.gd")

const CELL := 26
const ORIGIN := Vector2(40, 92)
const WORLD_SCENE := "res://scenes/world/world_scene.tscn"
const BATTLE_SCENE := "res://scenes/battle/battle_scene.tscn"
const MAZE_SCENE := "res://scenes/world/maze_scene.tscn"

var _gd: Node
var _gs: Node
var _maze: Dictionary
var _grid: Array
var _pos: Vector2i
var _start: Vector2i
var _boss_tile: Vector2i
var _hidden_tile: Vector2i
var _steps := 0
var _rng := RandomNumberGenerator.new()

var _car: ColorRect
var _hud: Label
var _hint: Label


func _ready() -> void:
	_gd = get_node("/root/GameData")
	_gs = get_node("/root/GameState")
	_maze = _gd.maze
	_grid = MRules.build_grid(_maze)
	_start = MRules.point("start", _maze)
	_boss_tile = MRules.point("boss", _maze)
	_hidden_tile = MRules.point("hidden", _maze)
	_pos = _restore_pos()
	_rng.randomize()
	_build_ui()
	_refresh_hud()
	_set_hint("方向键 / WASD 移动 · 回到绿色入口按 E 或 ESC 回地面 · %s" % _maze.get("name", "基地"))


func _restore_pos() -> Vector2i:
	var saved: Array = _gs.maze_pos
	if saved.size() >= 2:
		var t := Vector2i(int(saved[0]), int(saved[1]))
		if MRules.walkable_in(_grid, t):
			return t
	return _start


# -------------------- UI --------------------

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var title := Label.new()
	title.text = str(_maze.get("name", "迷宫"))
	title.add_theme_font_size_override("font_size", 22)
	title.anchor_left = 0.02; title.anchor_right = 0.98
	title.anchor_top = 0.01; title.anchor_bottom = 0.05
	add_child(title)

	_hud = Label.new()
	_hud.add_theme_font_size_override("font_size", 13)
	_hud.anchor_left = 0.02; _hud.anchor_right = 0.98
	_hud.anchor_top = 0.05; _hud.anchor_bottom = 0.075
	add_child(_hud)

	var legend := Label.new()
	legend.text = "深灰=墙   绿=入口   红=赏金首「天蝎」   黄=埋着的旧引擎"
	legend.add_theme_font_size_override("font_size", 12)
	legend.modulate = Color(0.7, 0.75, 0.8)
	legend.anchor_left = 0.02; legend.anchor_right = 0.98
	legend.anchor_top = 0.075; legend.anchor_bottom = 0.095
	add_child(legend)

	var cols := int(_maze.cols)
	var rows := int(_maze.rows)
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.06, 0.07)
	bg.position = ORIGIN - Vector2(4, 4)
	bg.size = Vector2(cols * CELL + 8, rows * CELL + 8)
	add_child(bg)

	var area := Control.new()
	area.position = ORIGIN
	area.size = Vector2(cols * CELL, rows * CELL)
	add_child(area)

	var floor_tile := ColorRect.new()
	floor_tile.color = Color(0.17, 0.16, 0.15)
	floor_tile.position = Vector2.ZERO
	floor_tile.size = area.size
	floor_tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
	area.add_child(floor_tile)

	for y in rows:
		for x in cols:
			if not MRules.walkable_in(_grid, Vector2i(x, y)):
				var wall := ColorRect.new()
				wall.color = Color(0.28, 0.27, 0.30)
				wall.position = Vector2(x, y) * CELL
				wall.size = Vector2(CELL - 1, CELL - 1)
				wall.mouse_filter = Control.MOUSE_FILTER_IGNORE
				area.add_child(wall)

	area.add_child(_marker(_start, Color(0.35, 0.75, 0.45)))
	area.add_child(_marker(_boss_tile, Color(0.85, 0.30, 0.28)))
	if not bool(_gs.flags.get("hidden_engine_found", false)):
		area.add_child(_marker(_hidden_tile, Color(0.85, 0.78, 0.30)))

	_car = ColorRect.new()
	_car.color = Color(0.95, 0.85, 0.25)
	_car.size = Vector2(CELL - 4, CELL - 4)
	_car.position = Vector2(_pos) * CELL + Vector2(2, 2)
	area.add_child(_car)

	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", 13)
	_hint.modulate = Color(0.72, 0.85, 1.0)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.anchor_left = 0.02; _hint.anchor_right = 0.98
	_hint.anchor_top = 0.86; _hint.anchor_bottom = 0.98
	add_child(_hint)


func _marker(tile: Vector2i, color: Color) -> ColorRect:
	var r := ColorRect.new()
	r.color = color
	r.position = Vector2(tile) * CELL + Vector2(3, 3)
	r.size = Vector2(CELL - 6, CELL - 6)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


# -------------------- 移动 --------------------

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	var dir := Vector2i.ZERO
	match event.keycode:
		KEY_UP, KEY_W: dir = Vector2i(0, -1)
		KEY_DOWN, KEY_S: dir = Vector2i(0, 1)
		KEY_LEFT, KEY_A: dir = Vector2i(-1, 0)
		KEY_RIGHT, KEY_D: dir = Vector2i(1, 0)
		KEY_E, KEY_SPACE:
			_interact()
			return
		KEY_ESCAPE:
			_leave()
			return
	if dir != Vector2i.ZERO:
		_try_move(dir)


func _try_move(dir: Vector2i) -> void:
	var dest: Vector2i = _pos + dir
	if not MRules.walkable_in(_grid, dest):
		_set_hint("墙。")
		return
	_pos = dest
	_gs.maze_pos = [_pos.x, _pos.y]
	_car.position = Vector2(_pos) * CELL + Vector2(2, 2)
	_steps += 1
	_refresh_hud()

	if _pos == _hidden_tile:
		_grant_hidden_engine()
		return
	if _pos == _boss_tile:
		_try_boss()
		return

	var interval := int(_maze.get("encounter_step_interval", 2))
	if interval > 0 and _steps % interval == 0:
		var group := WRules.roll_encounter(_maze, _rng)
		if not group.is_empty():
			_start_battle(group)


func _interact() -> void:
	if _pos == _start:
		_leave()
		return
	if _pos == _hidden_tile:
		_grant_hidden_engine()
		return
	if _pos == _boss_tile:
		_try_boss()
		return
	_set_hint("这里只有锈蚀的钢筋混凝土。")


func _grant_hidden_engine() -> void:
	if bool(_gs.flags.get("hidden_engine_found", false)):
		_set_hint("空箱子。里面那台引擎已经被你搬走了。")
		return
	var reward := str(_maze.get("hidden_reward", "e_mid"))
	_gs.flags["hidden_engine_found"] = true
	_gs.owned_parts.append(reward)
	var row: Dictionary = _gd.engines[reward]
	_set_hint("★ 在角落翻出一台还能用的%s！已经塞进你的部件库（白嫖变强）。" % row.name)
	_refresh_hud()


func _try_boss() -> void:
	var boss := str(_maze.get("boss_enemy", "en2r_021"))
	if bool(_gs.defeated_bounties.get(boss, false)):
		_set_hint("「天蝎」的残骸已经冷透了。回城领赏吧。")
		return
	_gs.return_scene = MAZE_SCENE
	_gs.maze_pos = [_pos.x, _pos.y]
	_start_battle([boss])


func _start_battle(group: Array) -> void:
	_gs.pending_battle_enemies = group
	_gs.return_scene = MAZE_SCENE
	_gs.maze_pos = [_pos.x, _pos.y]
	get_tree().change_scene_to_file(BATTLE_SCENE)


func _leave() -> void:
	_gs.return_scene = WORLD_SCENE
	# 走出基地后回到基地门口，避免下次从地底穿出去
	var base_row: Dictionary = _gd.regions.get("z_base", {})
	if not base_row.is_empty():
		var r: Array = base_row.rect
		_gs.world_pos = [int(r[0]) + int(r[2]) - 1, int(r[1]) + int(r[3]) - 1]
	get_tree().change_scene_to_file(WORLD_SCENE)


# -------------------- 刷新 --------------------

func _refresh_hud() -> void:
	var chassis: Dictionary = _gd.chassis[_gs.vehicle_build.chassis_id]
	_hud.text = "现金 %dG   %s   装甲 %d/%d   乘员 HP %d/%d" % [
		_gs.gold, chassis.name,
		_gs.vehicle_aromor_current(), _gs.vehicle_armor_max(),
		_gs.player_hp, _gs.player_max_hp,
	]


func _set_hint(text: String) -> void:
	_hint.text = text
