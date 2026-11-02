extends Control
## 城镇「锈镇」：整屏 3/4 透视插画 + 自由驾驶战车。
## 插画与行走数据由 tools/gen_town_map.py 生成：
##   assets/maps/town_rust.png（1152×648 整屏图）
##   data/town_art.json（设计像素：spawn / bounds / exit.point / buildings[].door / blocked[]）
## 玩法：WASD 或方向键开车，撞到建筑会被挡住，靠近门口按 E / 空格进入设施，走到北口出城。

const TownPanel := preload("res://scripts/ui/town_panel.gd")
const TankWalker := preload("res://scripts/ui/tank_walker.gd")

const WORLD_SCENE := "res://scenes/world/world_scene.tscn"
const ART_PATH := "res://assets/maps/town_rust.png"
const DATA_PATH := "res://data/town_art.json"
const ART_SIZE := Vector2(1152.0, 648.0)

const SPEED := 258.0
const TANK_R := 22.0
const TANK_H := 58.0
const DEFAULT_HINT := "WASD / 方向键 驾驶战车 · 靠近门口按 E 进入 · 北口出城"

var _gd: Node
var _gs: Node
var _art: Dictionary
var _stage: Node2D
var _tank
var _prompt: Label
var _panel: Control
var _hud: Label
var _hint: Label

var _pos := Vector2.ZERO
var _bounds := Rect2(0, 0, 1152, 648)
var _blocks: Array[Rect2] = []
var _doors: Array[Dictionary] = []
var _exit_pos := Vector2.ZERO
var _exit_radius := 56.0
var _near: Dictionary = {}


func _ready() -> void:
	_gd = get_node("/root/GameData")
	_gs = get_node("/root/GameState")
	if _gs.vehicle_runtime.is_empty():
		_gs.init_runtime_from_build()
	_art = _load_art()
	_read_walk_data()
	_build_ui()
	_layout_stage()
	_refresh_hud()
	_set_hint(DEFAULT_HINT)


func _load_art() -> Dictionary:
	var txt := FileAccess.get_file_as_string(DATA_PATH)
	var parsed = JSON.parse_string(txt)
	if parsed is Dictionary:
		return parsed
	push_warning("town_art.json 读取失败：%s" % DATA_PATH)
	return {}


func _read_walk_data() -> void:
	var spawn: Array = _art.get("spawn", [540, 596])
	_pos = Vector2(float(spawn[0]), float(spawn[1]))

	var bd: Array = _art.get("bounds", [24, 26, 1104, 620])
	_bounds = Rect2(float(bd[0]), float(bd[1]), float(bd[2]), float(bd[3]))

	for row_v in _art.get("blocked", []):
		var row: Dictionary = row_v
		var r: Array = row.get("rect", [])
		if r.size() >= 4:
			_blocks.append(Rect2(float(r[0]), float(r[1]), float(r[2]), float(r[3])))

	for row_v in _art.get("buildings", []):
		var row: Dictionary = row_v
		var door: Array = row.get("door", [])
		if door.size() < 2:
			continue
		_doors.append({
			"kind": str(row.get("kind", "bar")),
			"name": str(row.get("name", "")),
			"pos": Vector2(float(door[0]), float(door[1])),
			"radius": float(row.get("radius", 78.0)),
		})

	var ex: Dictionary = _art.get("exit", {})
	var pt: Array = ex.get("point", [730, 44])
	_exit_pos = Vector2(float(pt[0]), float(pt[1]))
	_exit_radius = float(ex.get("radius", 56.0))


# -------------------- UI --------------------

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = Color(0.10, 0.08, 0.06)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	_stage = Node2D.new()
	add_child(_stage)

	var tex := TextureRect.new()
	tex.texture = load(ART_PATH)
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_SCALE
	tex.position = Vector2.ZERO
	tex.size = ART_SIZE
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(tex)

	_tank = TankWalker.new()
	_tank.display_height = TANK_H
	_tank.position = _pos
	_stage.add_child(_tank)

	_prompt = Label.new()
	_prompt.text = "E"
	_prompt.visible = false
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.add_theme_font_size_override("font_size", 15)
	_prompt.add_theme_color_override("font_color", Color(1.0, 0.94, 0.62))
	_prompt.add_theme_color_override("font_outline_color", Color(0.05, 0.04, 0.03, 0.95))
	_prompt.add_theme_constant_override("outline_size", 6)
	_prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(_prompt)

	_build_header()
	_build_footer()


func _build_header() -> void:
	var title := Label.new()
	title.text = "锈镇 · 北岸聚落"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(1.0, 0.94, 0.80))
	title.add_theme_color_override("font_outline_color", Color(0.05, 0.04, 0.03, 0.95))
	title.add_theme_constant_override("outline_size", 8)
	title.position = Vector2(28, 18)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(title)

	_hud = Label.new()
	_hud.add_theme_font_size_override("font_size", 14)
	_hud.add_theme_color_override("font_color", Color(0.96, 0.92, 0.80))
	_hud.add_theme_color_override("font_outline_color", Color(0.05, 0.04, 0.03, 0.95))
	_hud.add_theme_constant_override("outline_size", 6)
	_hud.position = Vector2(30, 52)
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hud)


func _build_footer() -> void:
	_hint = Label.new()
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.anchor_left = 0.0
	_hint.anchor_right = 1.0
	_hint.anchor_top = 1.0
	_hint.anchor_bottom = 1.0
	_hint.offset_top = -36
	_hint.offset_bottom = -10
	_hint.add_theme_font_size_override("font_size", 15)
	_hint.add_theme_color_override("font_color", Color(0.84, 0.90, 1.0))
	_hint.add_theme_color_override("font_outline_color", Color(0.04, 0.04, 0.05, 0.95))
	_hint.add_theme_constant_override("outline_size", 6)
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hint)


# -------------------- 布局 --------------------

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout_stage()


func _layout_stage() -> void:
	if _stage == null:
		return
	var vp := size
	if vp.x <= 0.0 or vp.y <= 0.0:
		return
	var k := minf(vp.x / ART_SIZE.x, vp.y / ART_SIZE.y)
	_stage.scale = Vector2(k, k)
	_stage.position = (vp - ART_SIZE * k) * 0.5


func _refresh_hud() -> void:
	var chassis: Dictionary = _gd.chassis[_gs.vehicle_build.chassis_id]
	_hud.text = "现金 %dG   %s   装甲 %d/%d   乘员 HP %d/%d" % [
		_gs.gold, str(chassis.name),
		_gs.vehicle_aromor_current(), _gs.vehicle_armor_max(),
		_gs.player_hp, _gs.player_max_hp,
	]


# -------------------- 驾驶 --------------------

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


func _process(delta: float) -> void:
	if _panel != null or _tank == null:
		return
	var dir := _read_dir()
	if dir != Vector2.ZERO:
		dir = dir.normalized()
		_tank.walk(dir)
		_move_by(dir * SPEED * delta)
	else:
		_tank.idle()
	_update_near()


func _blocked(p: Vector2) -> bool:
	for r in _blocks:
		if r.grow(TANK_R).has_point(p):
			return true
	return false


func _move_by(delta: Vector2) -> void:
	var nx := Vector2(_pos.x + delta.x, _pos.y)
	if not _blocked(nx):
		_pos.x = nx.x
	var ny := Vector2(_pos.x, _pos.y + delta.y)
	if not _blocked(ny):
		_pos.y = ny.y
	_pos.x = clampf(_pos.x, _bounds.position.x, _bounds.end.x)
	_pos.y = clampf(_pos.y, _bounds.position.y, _bounds.end.y)
	_tank.position = _pos


func _update_near() -> void:
	var best: Dictionary = {}
	var best_d := 1e9
	for row in _doors:
		var dist := _pos.distance_to(row["pos"])
		if dist <= float(row["radius"]) and dist < best_d:
			best = row
			best_d = dist
	_near = best
	if not best.is_empty():
		var dp: Vector2 = best["pos"]
		_prompt.visible = true
		_prompt.position = Vector2(dp.x - 8.0, dp.y - 44.0)
		_set_hint("按 E / 空格 进入「%s」" % str(best["name"]))
		return
	_prompt.visible = false
	if _pos.distance_to(_exit_pos) <= _exit_radius:
		_set_hint("按 E / 空格 出城 · 1 号公路")
	else:
		_set_hint(DEFAULT_HINT)


# -------------------- 交互 --------------------

func _unhandled_input(event: InputEvent) -> void:
	if _panel != null:
		return
	if not (event is InputEventKey) or not event.pressed:
		return
	if event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_leave_town()
		return
	if event.keycode == KEY_E or event.keycode == KEY_SPACE:
		get_viewport().set_input_as_handled()
		if not _near.is_empty():
			_open_panel(str(_near["kind"]), str(_near["name"]))
		elif _pos.distance_to(_exit_pos) <= _exit_radius:
			_leave_town()


func _leave_town() -> void:
	if _panel != null:
		return
	_gs.return_scene = WORLD_SCENE
	get_tree().change_scene_to_file(WORLD_SCENE)


func _open_panel(kind: String, title: String) -> void:
	if _panel != null:
		return
	_panel = TownPanel.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_panel)
	_panel.open(kind, title, func(): _close_panel())
	_set_hint("%s —— Esc 离开柜台" % title)


func _close_panel() -> void:
	if _panel == null:
		return
	_panel.queue_free()
	_panel = null
	_refresh_hud()
	_set_hint(DEFAULT_HINT)


func _set_hint(text: String) -> void:
	if _hint != null:
		_hint.text = text
