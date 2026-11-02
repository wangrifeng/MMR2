extends Control
## M3 野外：贴图世界地图 + 连续自由驾驶 + 按距离遭遇 + 城镇/基地/NPC 入口。
## 底图由 tools/gen_world_map.py 按 regions.json 生成，规则仍走 world_rules.gd。
## 手感和城镇统一：WASD / 方向键按住连续行驶，撞不可通行地形会被挡住。

const Rules := preload("res://scripts/world/world_rules.gd")
const TankWalker := preload("res://scripts/ui/tank_walker.gd")

const CELL := 17
const ORIGIN := Vector2(14, 58)
const SPEED := 258.0
const MAP_TEXTURE := "res://assets/maps/world_rust.png"
const WORLD_SCENE := "res://scenes/world/world_scene.tscn"
const TOWN_SCENE := "res://scenes/world/town_scene.tscn"
const MAZE_SCENE := "res://scenes/world/maze_scene.tscn"
const BATTLE_SCENE := "res://scenes/battle/battle_scene.tscn"

const TERRAIN_LABEL := {"road": "公路", "sand": "沙地", "mountain": "山地"}
const LABEL_COLOR := {
	"town": Color(1.0, 0.86, 0.32),
	"base": Color(1.0, 0.66, 0.52),
	"npc": Color(0.72, 1.0, 0.74),
	"zone": Color(1.0, 0.9, 0.66),
}

var _gd: Node
var _gs: Node
var _zones: Dictionary
var _world: Dictionary

var _pos: Vector2i          # 当前所处格子（存 save / zone_at 用）
var _px := Vector2.ZERO     # 像素位置（_map_area 局部坐标，战车中心）
var _pixels_walked := 0.0   # 累计行驶像素，用于按距离触发遭遇
var _interval_px := 0.0     # 触发遭遇的像素间隔 = encounter_step_interval * CELL
var _rng := RandomNumberGenerator.new()
var _bounds := Rect2()      # _map_area 内部的可通行边界

var _car
var _hud: Label
var _zone_label: Label
var _hint: Label
var _map_area: Control
var _prompt: Label


func _ready() -> void:
	_gd = get_node("/root/GameData")
	_gs = get_node("/root/GameState")
	_zones = _gd.regions
	_world = _gd.regions_world
	_rng.randomize()
	if _gs.vehicle_runtime.is_empty():
		_gs.init_runtime_from_build()
	_restore_pos()
	_interval_px = float(int(_world.get("encounter_step_interval", 3))) * float(CELL)
	_build_ui()
	_refresh_hud()
	_gs.gold_changed.connect(func(_v): _refresh_hud())
	_set_hint("WASD / 方向键 驾驶战车 · 城镇、基地、机修工旁按 E 进入 · 每 %.0f 米可能遭遇" % _interval_px)


func _restore_pos() -> void:
	var saved: Array = _gs.world_pos
	var tile: Vector2i
	if saved.size() >= 2:
		tile = Vector2i(int(saved[0]), int(saved[1]))
	else:
		tile = Rules.start_tile(_world)
	_pos = tile
	_px = _tile_center(tile)


# -------------------- UI --------------------

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	_hud = Label.new()
	_hud.add_theme_font_size_override("font_size", 15)
	_hud.anchor_left = 0.02; _hud.anchor_right = 0.98
	_hud.anchor_top = 0.015; _hud.anchor_bottom = 0.05
	add_child(_hud)

	_zone_label = Label.new()
	_zone_label.add_theme_font_size_override("font_size", 17)
	_zone_label.modulate = Color(1.0, 0.92, 0.7)
	_zone_label.anchor_left = 0.02; _zone_label.anchor_right = 0.98
	_zone_label.anchor_top = 0.05; _zone_label.anchor_bottom = 0.08
	add_child(_zone_label)

	_map_area = Control.new()
	_map_area.position = ORIGIN
	_map_area.size = Vector2(int(_world.cols) * CELL, int(_world.rows) * CELL)
	add_child(_map_area)
	_bounds = Rect2(Vector2.ZERO, _map_area.size)

	var tex := TextureRect.new()
	tex.texture = load(MAP_TEXTURE)
	tex.position = Vector2.ZERO
	tex.size = _map_area.size
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_SCALE
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map_area.add_child(tex)

	_place_labels()

	_car = TankWalker.new()
	_car.display_height = 18.0
	_car.position = _px
	_map_area.add_child(_car)

	_prompt = Label.new()
	_prompt.text = "E"
	_prompt.visible = false
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.add_theme_font_size_override("font_size", 14)
	_prompt.add_theme_color_override("font_color", Color(1.0, 0.94, 0.62))
	_prompt.add_theme_color_override("font_outline_color", Color(0.05, 0.04, 0.03, 0.95))
	_prompt.add_theme_constant_override("outline_size", 5)
	_prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map_area.add_child(_prompt)

	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", 13)
	_hint.modulate = Color(0.72, 0.85, 1.0)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.anchor_left = 0.02; _hint.anchor_right = 0.98
	_hint.anchor_top = 0.93; _hint.anchor_bottom = 0.99
	add_child(_hint)


## 地名直接压在地图上：小字 + 黑描边，和底图的画风一致；公路只算地形，不标名字。
func _place_labels() -> void:
	for key in _zones.keys():
		var row: Dictionary = _zones[key]
		var kind := str(row.get("kind", "zone"))
		var terrain := str(row.get("terrain", ""))
		if kind == "zone" and terrain == "road":
			continue
		var r: Array = row.get("rect", [])
		if r.size() < 4:
			continue
		var tag := Label.new()
		tag.text = str(row.get("name", ""))
		tag.add_theme_font_size_override("font_size", 11)
		tag.add_theme_color_override("font_color", LABEL_COLOR.get(kind, LABEL_COLOR["zone"]))
		tag.add_theme_color_override("font_outline_color", Color(0.05, 0.04, 0.03, 0.92))
		tag.add_theme_constant_override("outline_size", 4)
		tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var cx := (float(int(r[0])) + float(int(r[2])) * 0.5) * CELL
		var cy := (float(int(r[1])) + float(int(r[3])) * 0.5) * CELL - 8.0
		_map_area.add_child(tag)
		tag.position = Vector2(cx - tag.get_minimum_size().x * 0.5, cy - 9.0)


func _tile_center(tile: Vector2i) -> Vector2:
	return Vector2(float(tile.x) * float(CELL) + float(CELL) * 0.5,
	               float(tile.y) * float(CELL) + float(CELL) * 0.5)


func _pos_at(px: Vector2) -> Vector2i:
	return Vector2i(int(px.x / CELL), int(px.y / CELL))


# -------------------- 驾驶 --------------------

func _process(delta: float) -> void:
	var dir := _read_dir()
	if dir != Vector2.ZERO:
		dir = dir.normalized()
		_car.walk(dir)
		_move_by(dir * SPEED * delta)
	else:
		_car.idle()
	_update_near()


func _read_dir() -> Vector2:
	var v := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		v.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		v.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		v.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		v.y += 1.0
	return v


func _move_by(delta: Vector2) -> void:
	# 分轴移动 + 地形判定：每一步只走能走的方向
	var nx := Vector2(_px.x + delta.x, _px.y)
	if _can_stand_at(nx):
		_px.x = nx.x
	var ny := Vector2(_px.x, _px.y + delta.y)
	if _can_stand_at(ny):
		_px.y = ny.y
	# clamp 到地图边界
	_px.x = clampf(_px.x, _bounds.position.x + 4.0, _bounds.end.x - 4.0)
	_px.y = clampf(_px.y, _bounds.position.y + 4.0, _bounds.end.y - 4.0)

	var moved := delta.length()
	if moved > 0.0:
		_pixels_walked += moved
		if _pixels_walked >= _interval_px:
			_pixels_walked -= _interval_px
			var group := Rules.roll_encounter(Rules.zone_at(_zones, _pos), _rng)
			if not group.is_empty():
				_car.idle()
				_start_battle(group)
				return

	# 更新格子坐标（只在跨格时才刷新 HUD / 存 save）
	var new_pos := _pos_at(_px)
	if new_pos != _pos:
		_pos = new_pos
		_gs.world_pos = [_pos.x, _pos.y]
		_refresh_hud()

	_car.position = _px


func _can_stand_at(px: Vector2) -> bool:
	# 地图边界判定
	if px.x < _bounds.position.x or px.x > _bounds.end.x:
		return false
	if px.y < _bounds.position.y or px.y > _bounds.end.y:
		return false
	var tile := _pos_at(px)
	var zone := Rules.zone_at(_zones, tile)
	if zone.is_empty():
		return false
	if not Rules.passable(zone, _gs.chassis_terrain()):
		return false
	return true


func _update_near() -> void:
	var zone := Rules.zone_at(_zones, _pos)
	var kind := str(zone.get("kind", "zone"))
	if kind == "town" or kind == "base" or kind == "npc":
		_prompt.visible = true
		var center := _tile_center(_pos)
		_prompt.position = center + Vector2(-7.0, -18.0)
		var label := str(zone.get("name", ""))
		match kind:
			"town": _set_hint("按 E 进入「%s」" % label)
			"base": _set_hint("按 E 进入「%s」（补给 / 修理）" % label)
			"npc": _set_hint("按 E 和「%s」对话" % label)
		return
	_prompt.visible = false
	_set_hint("WASD / 方向键 驾驶战车 · 城镇、基地、机修工旁按 E 进入 · 每 %.0f 米可能遭遇" % _interval_px)


# -------------------- 交互 --------------------

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	match event.keycode:
		KEY_E, KEY_SPACE:
			event.accept_event()
			_enter_here()
		KEY_ESCAPE:
			get_tree().change_scene_to_file(TOWN_SCENE)


func _enter_here() -> void:
	var zone := Rules.zone_at(_zones, _pos)
	var kind := str(zone.get("kind", "zone"))
	match kind:
		"town":
			_gs.return_scene = WORLD_SCENE
			get_tree().change_scene_to_file(TOWN_SCENE)
		"base":
			_gs.maze_pos = _gd.maze.get("start", [1, 1])
			_gs.return_scene = WORLD_SCENE
			get_tree().change_scene_to_file(MAZE_SCENE)
		"npc":
			_talk_npc(zone)
		_:
			_set_hint(str(zone.get("desc", "这里什么都没有。")))


func _talk_npc(zone: Dictionary) -> void:
	var quest_id := str(zone.get("quest", ""))
	if quest_id.is_empty():
		_set_hint("%s：%s" % [zone.get("name", "路人"), zone.get("desc", "")])
		return
	var res: Dictionary = _gs.deliver_quest(quest_id)
	_set_hint("%s：%s" % [zone.get("name", "路人"), res.get("msg", "")])
	_refresh_hud()


func _start_battle(group: Array) -> void:
	_gs.pending_battle_enemies = group
	_gs.return_scene = WORLD_SCENE
	_gs.world_pos = [_pos.x, _pos.y]
	get_tree().change_scene_to_file(BATTLE_SCENE)


# -------------------- 刷新 --------------------

func _refresh_hud() -> void:
	var chassis: Dictionary = _gd.chassis[_gs.vehicle_build.chassis_id]
	var names: Array = []
	for t in _gs.chassis_terrain():
		names.append(TERRAIN_LABEL.get(str(t), str(t)))
	_hud.text = "现金 %dG   %s   装甲 %d/%d   乘员 HP %d/%d   可走地形：%s" % [
		_gs.gold, chassis.name,
		_gs.vehicle_aromor_current(), _gs.vehicle_armor_max(),
		_gs.player_hp, _gs.player_max_hp,
		"/".join(names),
	]
	var zone := Rules.zone_at(_zones, _pos)
	if zone.is_empty():
		_zone_label.text = ""
		return
	var kind := str(zone.get("kind", "zone"))
	var safe := kind != "zone" or float(zone.get("encounter_chance", 0.0)) <= 0.0
	var t_key := str(zone.get("terrain", ""))
	var terrain := str(TERRAIN_LABEL.get(t_key, t_key))
	_zone_label.text = "%s（%s）%s" % [zone.get("name", ""), terrain, "· 安全" if safe else "· 有遭遇"]


func _set_hint(text: String) -> void:
	_hint.text = text
