extends Control
## 六边形棋盘：地面、格子、单位图形、高亮与点击映射。
## 坐标与 hex_rules 一致：Vector2i(col, row)，odd-r 偏移。
## 单位图形：我方战车用 red tank 立绘贴图，其余用 _draw 画成几何图形。

signal cell_clicked(cell: Vector2i)

const TANK_TEX := preload("res://assets/battle/tank_player.png")
const TANK_FIRE := preload("res://assets/battle/tank_fire_sheet.png")
const TANK_DRIVE := preload("res://assets/battle/tank_drive_sheet.png")
const SHELL_TEX := preload("res://assets/battle/shell.png")
## 战场底图：障碍物格先铺上同一张底图在对应位置的像素，和周围沙漠无缝衔接。
const BG_TEX := preload("res://assets/battle/bg_desert.png")
## 障碍物贴图：四张沙漠障碍插画，按格子哈希挑一张铺进六边形。
const OBSTACLE_TEXES := [
	preload("res://assets/battle/obstacle_1.png"),
	preload("res://assets/battle/obstacle_2.png"),
	preload("res://assets/battle/obstacle_3.png"),
	preload("res://assets/battle/obstacle_4.png"),
]
const FIRE_FRAMES := 4
const FIRE_DURATION := 0.42      # 开火动画总时长（秒）
const DRIVE_FRAMES := 8
const DRIVE_FRAME_TIME := 0.18   # 行驶循环单帧时长（秒）
const MOVE_SEC_PER_HEX := 0.50   # 走过一格花多久

var grid_cols: int = 11
var grid_rows: int = 9
var hex_size: float = 30.0

var units: Array = []
var active_unit = null
var selected_unit = null
var reachable: Dictionary = {}
var attack_cells: Dictionary = {}
var blocked_map: Dictionary = {}
var hovered: Vector2i = Vector2i(-1, -1)

var _clock: float = 0.0
var _firing_unit = null
var _fire_time: float = 0.0
var _move_unit = null
var _move_path: Array = []
var _move_time: float = 0.0
var _drive_clock: float = 0.0
var _move_dir: float = 1.0
var _shots: Array = []      # 飞行中的炮弹 {from, to, t, dur, cells}
var _booms: Array = []      # 受击爆炸 {cell, t, spin}
const BOOM_DURATION := 0.80
var _popups: Array = []     # 头顶飘字 {pos, text, style, t, delay, dur}
const POPUP_DURATION := 0.95
const POPUP_STACK_STEP := 0.34   # 同一格多次命中时逐条向上错开（按 hex_size 倍数）

var _enemy_tex_cache: Dictionary = {}   # 敌人贴图路径 → Texture2D（无图存 null）


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_exited.connect(_on_mouse_exited)
	set_process(true)


func set_state(cols: int, rows: int, unit_list: Array, active,
		reach_map: Dictionary, attack_map: Dictionary, selected = null,
		blocked_cells: Dictionary = {}) -> void:
	grid_cols = cols
	grid_rows = rows
	units = unit_list
	active_unit = active
	reachable = reach_map
	attack_cells = attack_map
	selected_unit = selected
	blocked_map = blocked_cells
	queue_redraw()


func _process(delta: float) -> void:
	if active_unit == null and _firing_unit == null and _move_unit == null \
			and _shots.is_empty() and _booms.is_empty() and _popups.is_empty():
		return
	_clock += delta
	if _firing_unit != null:
		_fire_time += delta
		if _fire_time >= FIRE_DURATION:
			_firing_unit = null
	if _move_unit != null:
		_move_time += delta
		_drive_clock += delta
		if _move_time >= MOVE_SEC_PER_HEX * float(_move_path.size() - 1):
			_move_unit = null
	_tick_shots(delta)
	_tick_booms(delta)
	_tick_popups(delta)
	queue_redraw()


func play_fire(unit) -> void:
	## 战车开火动画：只在轮到我自己开炮时播，敌人和其它单位不播。
	if unit == null or not (unit.is_vehicle and unit.is_player):
		return
	_firing_unit = unit
	_fire_time = 0.0
	set_process(true)
	queue_redraw()


func play_move(unit, from_cell: Vector2i, path: Array) -> void:
	## 战车沿着寻路结果一格一格开过去，而不是瞬移。
	if unit == null or path.is_empty():
		return
	_move_unit = unit
	_move_path = [from_cell]
	for cell in path:
		_move_path.append(cell)
	_move_time = 0.0
	_drive_clock = 0.0
	var n: int = _move_path.size()
	var dx: float = cell_center(_move_path[n - 1]).x - cell_center(_move_path[n - 2]).x
	_move_dir = signf(dx) if absf(dx) > 1.0 else _move_dir
	set_process(true)
	queue_redraw()


func play_attack(attacker, weapon: Dictionary, results: Array) -> void:
	## 开火特写：战车先播后坐帧，远程武器再飞一颗炮弹过去，命中后目标身上炸开；
	## 同时在每个受击单位头顶飘出伤害数字（白=普通，红=暴击，彩虹=真实暴击，MISS=未命中）。
	if attacker == null:
		return
	if attacker.is_vehicle and attacker.is_player:
		play_fire(attacker)
	var melee := bool(weapon.get("melee", false))
	var cells: Array = []
	var stack: Dictionary = {}
	var from: Vector2 = _unit_pos(attacker)
	for r in results:
		# 被障碍物挡住的射击把炮弹落在障碍物上；打碎障碍物的结果本身 target 为 null
		var blocked_cell = r.get("blocked_cell", null)
		if blocked_cell != null and blocked_cell.x >= 0:
			cells.append(blocked_cell)
			continue
		var t = r.get("target", null)
		if t != null:
			cells.append(t.cell)
			var key: String = "%d,%d" % [t.cell.x, t.cell.y]
			var n: int = int(stack.get(key, 0))
			stack[key] = n + 1
			var delay := 0.0
			if not melee:
				delay = clampf(from.distance_to(cell_center(t.cell)) / hex_size * 0.045,
					0.09, 0.26)
			_spawn_popup(t, r, n, delay)
	if cells.is_empty():
		return
	if melee:
		for cell in cells:
			_spawn_boom(cell)
		queue_redraw()
		return
	var to: Vector2 = cell_center(cells[0])
	var dir: Vector2 = (to - from)
	if dir.length() < 1.0:
		dir = Vector2(1, 0)
	dir = dir.normalized()
	var travel: float = clampf(from.distance_to(to) / hex_size * 0.045, 0.09, 0.26)
	_shots.append({
		"from": from + dir * hex_size * 0.85, "to": to, "dir": dir,
		"t": 0.0, "dur": travel, "cells": cells,
	})
	set_process(true)
	queue_redraw()


func _tick_shots(delta: float) -> void:
	if _shots.is_empty():
		return
	var done: Array = []
	for s in _shots:
		s.t += delta
		if s.t >= s.dur:
			for cell in s.cells:
				_spawn_boom(cell)
			done.append(s)
	for s in done:
		_shots.erase(s)


func _spawn_boom(cell: Vector2i) -> void:
	_booms.append({
		"cell": cell, "t": 0.0,
		"spin": float((cell.x * 31 + cell.y * 17) % 7) * 0.31,
	})
	set_process(true)


func _tick_booms(delta: float) -> void:
	if _booms.is_empty():
		return
	var alive: Array = []
	for b in _booms:
		b.t += delta
		if b.t < BOOM_DURATION:
			alive.append(b)
	_booms = alive


func _spawn_popup(target, result: Dictionary, stack_index: int, delay: float) -> void:
	## 受击飘字：命中显示伤害数字，未命中显示 MISS 并标错。
	var hit := bool(result.get("hit", false))
	var style := "miss"
	if hit:
		style = str(result.get("crit", "none"))
	var text := "MISS" if not hit else str(int(result.get("damage", 0)))
	var pos: Vector2 = cell_center(target.cell) \
		+ Vector2(0, -hex_size * 1.30 - float(stack_index) * hex_size * POPUP_STACK_STEP)
	_popups.append({"pos": pos, "text": text, "style": style, "t": 0.0,
		"delay": delay, "dur": POPUP_DURATION})
	set_process(true)


func _tick_popups(delta: float) -> void:
	if _popups.is_empty():
		return
	var alive: Array = []
	for p in _popups:
		if p.delay > 0.0:
			p.delay -= delta
			alive.append(p)
			continue
		p.t += delta
		if p.t < p.dur:
			alive.append(p)
	_popups = alive


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var cell := cell_at(event.position)
		if cell != hovered:
			hovered = cell
			queue_redraw()
	elif event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		var cell := cell_at(event.position)
		if cell.x >= 0:
			cell_clicked.emit(cell)


func _on_mouse_exited() -> void:
	hovered = Vector2i(-1, -1)
	queue_redraw()


# -------------------- 几何 --------------------

func _metrics() -> Dictionary:
	var width := size.x if size.x > 0 else 800.0
	var height := size.y if size.y > 0 else 520.0
	var by_width := width / (sqrt(3.0) * (float(grid_cols) + 0.5))
	var by_height := height / (1.5 * float(maxi(1, grid_rows - 1)) + 2.0)
	hex_size = clampf(minf(by_width, by_height), 14.0, 44.0)
	var total_w := sqrt(3.0) * hex_size * (float(grid_cols) + 0.5)
	var total_h := 1.5 * hex_size * float(grid_rows - 1) + 2.0 * hex_size
	var origin := Vector2((width - total_w) * 0.5, (height - total_h) * 0.5)
	return {"origin": origin, "w": sqrt(3.0) * hex_size}


func cell_center(cell: Vector2i) -> Vector2:
	var m := _metrics()
	var origin: Vector2 = m.origin
	var w: float = m.w
	return Vector2(
		origin.x + w * (float(cell.x) + 0.5 * float(cell.y & 1)) + w * 0.5,
		origin.y + hex_size + 1.5 * hex_size * float(cell.y)
	)


func cell_at(pos: Vector2) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_dist := hex_size * 1.02
	for x in grid_cols:
		for y in grid_rows:
			var cell := Vector2i(x, y)
			var d: float = pos.distance_to(cell_center(cell))
			if d < best_dist:
				best_dist = d
				best = cell
	return best


func _hex_points(center: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in 6:
		var angle := deg_to_rad(60.0 * float(i) - 90.0)
		out.append(center + Vector2(cos(angle), sin(angle)) * hex_size)
	return out


func _closed(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array(pts)
	out.append(pts[0])
	return out


func _ellipse(center: Vector2, rx: float, ry: float, color: Color) -> void:
	var pts := PackedVector2Array()
	for i in 20:
		var a := TAU * float(i) / 20.0
		pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	draw_colored_polygon(pts, color)


# -------------------- 绘制 --------------------

func _draw() -> void:
	_metrics()
	var font := get_theme_default_font()
	for x in grid_cols:
		for y in grid_rows:
			_draw_hex(Vector2i(x, y))
	for cell in blocked_map.keys():
		_draw_rock(cell)
	for u in units:
		if u.is_alive():
			_draw_unit(u, font)
	_draw_shots()
	_draw_booms()
	_draw_popups(font)
	_draw_hint(font)


func _draw_shots() -> void:
	for s in _shots:
		var k: float = clampf(s.t / s.dur, 0.0, 1.0)
		var from_p: Vector2 = s.from
		var to_p: Vector2 = s.to
		var pos: Vector2 = from_p.lerp(to_p, k)
		var dir: Vector2 = s.dir
		# 尾迹：越靠近炮口越长越亮
		var tail := pos - dir * hex_size * (0.9 + 0.6 * k)
		draw_line(tail, pos, Color(1.0, 0.83, 0.48, 0.34), 2.2)
		draw_line(pos - dir * hex_size * 0.5, pos, Color(1.0, 0.95, 0.80, 0.55), 1.4)
		draw_circle(pos, hex_size * 0.16, Color(1.0, 0.90, 0.62, 0.55))
		var w: float = hex_size * 1.55
		var h: float = w * float(SHELL_TEX.get_height()) / float(SHELL_TEX.get_width())
		draw_set_transform(pos, dir.angle(), Vector2.ONE)
		draw_texture_rect(SHELL_TEX, Rect2(-w * 0.70, -h * 0.5, w, h), false)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_booms() -> void:
	for b in _booms:
		var t: float = clampf(b.t / BOOM_DURATION, 0.0, 1.0)
		var c: Vector2 = cell_center(b.cell) + Vector2(0, -hex_size * 0.10)
		var seed_v: float = b.spin
		# 命中瞬间的白闪 + 冲击波环
		var flash: float = clampf(1.0 - t * 3.0, 0.0, 1.0)
		if flash > 0.0:
			draw_circle(c, hex_size * (0.42 + 0.90 * (1.0 - flash)),
				Color(1.0, 0.98, 0.86, 0.92 * flash))
		var ring_r: float = hex_size * (0.40 + 1.45 * t)
		draw_arc(c, ring_r, 0.0, TAU, 30, Color(1.0, 0.90, 0.60, 0.70 * (1.0 - t)), 3.0)
		# 火球三层
		var r1: float = hex_size * (0.34 + 1.28 * t)
		draw_circle(c, r1, Color(0.94, 0.36, 0.06, 0.62 * (1.0 - t)))
		draw_circle(c, r1 * 0.74, Color(1.0, 0.62, 0.14, 0.82 * maxf(0.0, 1.0 - t * 1.25)))
		draw_circle(c, r1 * 0.44, Color(1.0, 0.94, 0.66, 0.95 * maxf(0.0, 1.0 - t * 1.6)))
		# 余烟
		if t > 0.30:
			var k: float = (t - 0.30) / 0.70
			draw_circle(c + Vector2(0, -hex_size * 0.34 * k), hex_size * (0.50 + 0.86 * k),
				Color(0.20, 0.18, 0.16, 0.42 * (1.0 - k)))
		# 溅射火星
		for i in 9:
			var a: float = TAU * float(i) / 9.0 + seed_v
			var len1: float = hex_size * (0.24 + 1.10 * t)
			var p0: Vector2 = c + Vector2(cos(a), sin(a)) * len1 * 0.52
			var p1: Vector2 = c + Vector2(cos(a), sin(a)) * len1
			draw_line(p0, p1, Color(1.0, 0.86, 0.46, 0.90 * (1.0 - t)), 2.0)


func _draw_popups(font) -> void:
	## 头顶飘字：先弹一下，再上浮淡出。颜色按结果区分。
	if font == null:
		return
	for p in _popups:
		if p.delay > 0.0:
			continue
		var k: float = clampf(p.t / p.dur, 0.0, 1.0)
		var alpha: float = 1.0 if k <= 0.62 else maxf(0.0, 1.0 - (k - 0.62) / 0.38)
		if alpha <= 0.0:
			continue
		var rise: float = -hex_size * 0.62 * (1.0 - pow(1.0 - k, 2.0))
		var s: float = 0.62 + 0.38 * clampf(p.t / 0.11, 0.0, 1.0)
		var fsize := clampi(int(hex_size * 0.64), 13, 32)
		if p.style == "crit":
			fsize = int(float(fsize) * 1.20)
		elif p.style == "true":
			fsize = int(float(fsize) * 1.38)
		elif p.style == "miss":
			fsize = int(float(fsize) * 0.92)
		var txt: String = p.text
		var txt_w: float = font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x
		var sx: float = -txt_w * 0.5
		var base_y: float = float(fsize) * 0.36
		var outline: int = maxi(2, int(round(float(fsize) * 0.14)))
		var outline_col := Color(0.06, 0.05, 0.04, 0.88 * alpha)
		draw_set_transform(p.pos + Vector2(0, rise), 0.0, Vector2(s, s))
		if p.style == "true":
			# 真实暴击：每个字单独取色，色相随时间滚动形成彩虹。
			var x: float = sx
			for i in txt.length():
				var ch: String = txt[i]
				var cw: float = font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1,
					fsize).x
				var col := Color.from_hsv(fmod(float(i) * 0.14 + _clock * 0.55, 1.0), 0.88, 1.0)
				col.a = alpha
				draw_string_outline(font, Vector2(x, base_y), ch, HORIZONTAL_ALIGNMENT_LEFT,
					-1, fsize, outline, outline_col)
				draw_string(font, Vector2(x, base_y), ch, HORIZONTAL_ALIGNMENT_LEFT,
					-1, fsize, col)
				x += cw
		else:
			var col := Color(1.0, 1.0, 1.0)
			if p.style == "crit":
				col = Color(1.0, 0.24, 0.16)
			elif p.style == "miss":
				col = Color(0.80, 0.84, 0.90)
			col.a = alpha
			draw_string_outline(font, Vector2(sx, base_y), txt, HORIZONTAL_ALIGNMENT_LEFT,
				txt_w, fsize, outline, outline_col)
			draw_string(font, Vector2(sx, base_y), txt, HORIZONTAL_ALIGNMENT_LEFT,
				txt_w, fsize, col)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_hex(cell: Vector2i) -> void:
	## 格子内部保持透明，直接透出沙漠插画；可达 / 射程只用彩色描边标出。
	var center := cell_center(cell)
	var pts := _hex_points(center)
	var edge := Color(0, 0, 0, 0)
	if reachable.has(cell):
		edge = Color(0.35, 0.68, 1.0, 0.90)
	if attack_cells.has(cell):
		# "rock" 的亮边留给障碍物本身画，这里不染格子
		if str(attack_cells[cell]) == "over":
			edge = Color(0.76, 0.50, 1.0, 0.95)
		elif str(attack_cells[cell]) == "in":
			edge = Color(1.0, 0.36, 0.26, 0.95)
	draw_polyline(_closed(pts), Color(0.10, 0.08, 0.06, 0.34), 1.0)
	if edge.a > 0.0:
		draw_polyline(_closed(pts), edge, 2.0)
	if cell == hovered:
		draw_polyline(_closed(pts), Color(1.0, 0.86, 0.35), 2.0)


func _draw_rock(cell: Vector2i) -> void:
	## 障碍物：先用战场底图在同一六边形位置的像素铺底，再把障碍插画淡淡叠上去。
	## 底色和周围沙漠完全一致，格子边缘不再出现一张突兀的"贴纸"。
	var c := cell_center(cell)
	var pts := _hex_points(c)
	# 底图按 cover 铺满父节点，换算出这块六边形落在底图上的 uv
	var bg_uvs := PackedVector2Array()
	var bg_colors := PackedColorArray()
	for p in pts:
		bg_uvs.append(_backdrop_uv(p))
		bg_colors.append(Color.WHITE)
	draw_polygon(pts, bg_colors, bg_uvs, BG_TEX)

	var tex: Texture2D = OBSTACLE_TEXES[absi(cell.x * 31 + cell.y * 17) % OBSTACLE_TEXES.size()]
	var tex_size := tex.get_size()
	# 只取画面中间偏下的一块方形（避开天空暗部、插画边缘和右下角水印）
	var side: float = minf(tex_size.x, tex_size.y) * 0.56
	var src := Rect2(Vector2(tex_size.x * 0.5 - side * 0.5, tex_size.y * 0.60 - side * 0.5),
		Vector2(side, side))
	var uvs := PackedVector2Array()
	var uv0: Vector2 = src.position / tex_size
	var uv1: Vector2 = (src.position + src.size) / tex_size
	for p in pts:
		var nx: float = (p.x - c.x) / (hex_size * sqrt(3.0) * 0.5)
		var ny: float = (p.y - c.y) / hex_size
		uvs.append(Vector2(lerpf(uv0.x, uv1.x, nx * 0.5 + 0.5),
			lerpf(uv0.y, uv1.y, ny * 0.5 + 0.5)))
	# 半透明叠加：保留沙丘/仙人掌的轮廓，插画自带的底色被下面的真实底色冲淡
	var colors := PackedColorArray()
	for i in pts.size():
		colors.append(Color(1.0, 0.96, 0.90, 0.55))
	draw_polygon(pts, colors, uvs, tex)
	draw_colored_polygon(pts, Color(0.30, 0.20, 0.10, 0.10))
	if str(attack_cells.get(cell, "")) == "rock":
		draw_polyline(_closed(pts), Color(1.0, 0.64, 0.28, 0.95), 2.0)
	if cell == hovered:
		draw_polyline(_closed(pts), Color(1.0, 0.86, 0.35), 2.0)


func _backdrop_uv(p: Vector2) -> Vector2:
	## 棋盘局部坐标 → 战场底图 uv。底图和 battle_scene 一样按 cover 铺满父节点。
	var host := get_parent() as Control
	if host == null:
		return Vector2.ZERO
	var tex_size := BG_TEX.get_size()
	var draw_size := tex_size * maxf(host.size.x / tex_size.x, host.size.y / tex_size.y)
	var origin := (host.size - draw_size) * 0.5
	return (position + p - origin) / draw_size


func _draw_unit(u, font) -> void:
	var center := _unit_pos(u)
	var radius := hex_size * 0.50
	var facing := 1.0 if u.is_player else -1.0
	_draw_unit_mark(u, center)
	draw_circle(center + Vector2(0, radius * 0.62), radius * 0.72, Color(0, 0, 0, 0.30))
	if u.is_vehicle and u.is_player:
		_draw_player_vehicle(u, center, radius, facing)
	elif u.is_vehicle:
		if not _draw_enemy_sprite(u, center, radius):
			_draw_enemy_machine(u, center, radius, facing)
	elif u.is_character:
		_draw_hero(u, center, radius, facing)
	else:
		if not _draw_enemy_sprite(u, center, radius):
			_draw_creature(u, center, radius, facing)
	_draw_bars(u, center, radius)
	if font != null:
		_draw_label(u, center, radius, font)


func _unit_pos(u) -> Vector2:
	## 行驶中的单位按寻路路径插值画在格子之间，其余单位直接用所在格中心。
	if _move_unit != u or _move_path.size() < 2:
		return cell_center(u.cell)
	var steps := _move_time / MOVE_SEC_PER_HEX
	var seg := int(steps)
	if seg >= _move_path.size() - 1:
		return cell_center(u.cell)
	return cell_center(_move_path[seg]).lerp(cell_center(_move_path[seg + 1]),
		steps - float(seg))


func _draw_label(u, center: Vector2, radius: float, font) -> void:
	var text: String = u.label.substr(0, 2)
	var pos := center + Vector2(-hex_size * 0.9, -hex_size * 0.86)
	draw_string(font, pos + Vector2(1, 1), text, HORIZONTAL_ALIGNMENT_CENTER,
		hex_size * 1.8, 12, Color(0.05, 0.04, 0.03, 0.95))
	draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_CENTER,
		hex_size * 1.8, 12, Color(0.95, 0.93, 0.86))
	if u == active_unit:
		draw_string(font, center + Vector2(-hex_size, radius * 1.9),
			"MP %d" % u.mp, HORIZONTAL_ALIGNMENT_CENTER, hex_size * 2.0, 10,
			Color(0.98, 0.85, 0.42))


func _draw_bars(u, center: Vector2, radius: float) -> void:
	var bar_w := hex_size * 0.98
	var x0 := center.x - bar_w * 0.5
	var y0 := center.y + radius * 0.95
	draw_rect(Rect2(x0 - 1.0, y0 - 1.0, bar_w + 2.0, 9.0), Color(0, 0, 0, 0.60))
	var hp_ratio := clampf(float(u.hp) / float(maxi(1, u.max_hp)), 0.0, 1.0)
	var hp_color := Color(0.88, 0.30, 0.26) if u.is_player else Color(0.95, 0.60, 0.24)
	draw_rect(Rect2(x0, y0, bar_w * hp_ratio, 3.6), hp_color)
	if u.is_vehicle:
		var armor_ratio := clampf(float(u.armor) / float(maxi(1, u.max_armor)), 0.0, 1.0)
		draw_rect(Rect2(x0, y0 + 4.2, bar_w * armor_ratio, 2.8), Color(0.48, 0.74, 0.98))


func _draw_unit_mark(u, center: Vector2) -> void:
	## 当前行动单位：所在格金色底光 + 描边，宽体载具再补一圈金色光晕；
	## 只是被点开查看的我方单位：青色细边。都不做旋转。
	var pts := _hex_points(cell_center(u.cell))
	if u == active_unit:
		var pulse := 0.5 + 0.5 * sin(_clock * 2.4)
		draw_colored_polygon(pts, Color(1.0, 0.80, 0.32, 0.16 + 0.10 * pulse))
		draw_polyline(_closed(pts), Color(1.0, 0.84, 0.36, 0.85 + 0.15 * pulse), 3.0)
		if u.is_vehicle:
			_ellipse(center, hex_size * 1.42, hex_size * 0.66,
				Color(1.0, 0.76, 0.28, 0.10 + 0.07 * pulse))
	elif u == selected_unit:
		draw_polyline(_closed(pts), Color(0.55, 0.86, 1.0, 0.85), 2.0)


# -------------------- 单位图形 --------------------

func _draw_player_vehicle(u, c: Vector2, r: float, f: float) -> void:
	## 我方战车用红坦克立绘（朝右），底边压在格子中线下沿，宽度略超出格子。
	## 行驶时播 GIF 拆出的行驶循环帧（朝行进方向），开火时播后坐帧并在炮口补一道火光。
	var tex_size := TANK_TEX.get_size()
	var draw_w := r * 5.0
	var draw_h := draw_w * tex_size.y / tex_size.x
	var box := Rect2(c.x - draw_w * 0.5, c.y + r * 0.92 - draw_h, draw_w, draw_h)
	var flip := false
	if _move_unit == u:
		var drive := TANK_DRIVE.get_size()
		var dw := drive.x / float(DRIVE_FRAMES)
		var frame := int(_drive_clock / DRIVE_FRAME_TIME) % DRIVE_FRAMES
		flip = _move_dir < 0.0
		_draw_sprite_region(TANK_DRIVE, box, Rect2(dw * float(frame), 0.0, dw, drive.y), flip, c)
	elif _firing_unit == u:
		var sheet := TANK_FIRE.get_size()
		var frame_w := sheet.x / float(FIRE_FRAMES)
		var frame_i := clampi(int(_fire_time / FIRE_DURATION * float(FIRE_FRAMES)),
			0, FIRE_FRAMES - 1)
		_draw_sprite_region(TANK_FIRE, box,
			Rect2(frame_w * float(frame_i), 0.0, frame_w, sheet.y), false, c)
		_draw_muzzle_flash(box, r)
	else:
		draw_texture_rect(TANK_TEX, box, false)
	if int(u.armor) <= 0:
		draw_rect(box, Color(0.05, 0.05, 0.06, 0.28))


func _draw_sprite_region(tex: Texture2D, box: Rect2, src: Rect2, flip: bool, pivot: Vector2) -> void:
	## 序列图取一帧画到 box；flip 时以 pivot 为轴水平镜像（战车朝左开）。
	if not flip:
		draw_texture_rect_region(tex, box, src)
		return
	draw_set_transform(pivot, 0.0, Vector2(-1, 1))
	draw_texture_rect_region(tex, Rect2(box.position - pivot, box.size), src)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_muzzle_flash(box: Rect2, r: float) -> void:
	## 炮口火光：前 40% 时间是爆闪，后面收成余烟。
	var t := _fire_time / FIRE_DURATION
	var power := 1.0 if t < 0.40 else maxf(0.0, 1.0 - (t - 0.40) / 0.60)
	var muzzle := Vector2(box.end.x - r * 0.10, box.position.y + box.size.y * 0.26)
	var flash_r := r * (0.34 + 0.20 * power)
	draw_circle(muzzle, flash_r * 1.6, Color(1.0, 0.62, 0.20, 0.22 * power))
	draw_circle(muzzle, flash_r, Color(1.0, 0.84, 0.42, 0.60 * power))
	draw_circle(muzzle, flash_r * 0.55, Color(1.0, 0.98, 0.86, 0.90 * power))
	draw_line(muzzle, muzzle + Vector2(r * 1.3 * power, -r * 0.08),
		Color(1.0, 0.92, 0.62, 0.50 * power), r * 0.10)


func _draw_enemy_sprite(u, c: Vector2, r: float) -> bool:
	## 敌人图鉴贴图：等比缩放，底边压在中线下沿；没有图就返回 false 交给几何图形兜底。
	var tex: Texture2D = _enemy_texture(u)
	if tex == null:
		return false
	var ts := tex.get_size()
	if ts.x <= 0.0 or ts.y <= 0.0:
		return false
	var scale := minf(r * 2.4 / ts.x, r * 2.1 / ts.y)
	var box := Rect2(c.x - ts.x * scale * 0.5, c.y + r * 0.62 - ts.y * scale,
		ts.x * scale, ts.y * scale)
	draw_texture_rect(tex, box, false)
	return true


func _enemy_texture(u) -> Texture2D:
	var path := str(u.sprite_path)
	if path.is_empty():
		return null
	if _enemy_tex_cache.has(path):
		return _enemy_tex_cache[path]
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path) as Texture2D
	_enemy_tex_cache[path] = tex
	return tex


func _draw_enemy_machine(_u, c: Vector2, r: float, f: float) -> void:
	var tint := Color(0.62, 0.30, 0.24)
	draw_rect(Rect2(c.x - r * 1.0, c.y - r * 0.36, r * 2.0, r * 0.62), tint.darkened(0.5))
	draw_rect(Rect2(c.x - r * 0.92, c.y - r * 0.30, r * 1.84, r * 0.50), tint)
	draw_line(c + Vector2(0, -r * 0.18), c + Vector2(f * r * 1.3, -r * 0.18),
		Color(0.16, 0.15, 0.14), 4.0)


func _draw_hero(u, c: Vector2, r: float, f: float) -> void:
	# 披风
	draw_line(c + Vector2(-f * r * 0.10, r * 0.10), c + Vector2(-f * r * 0.55, r * 0.50),
		Color(0.72, 0.32, 0.24), 3.0)
	# 身体
	draw_circle(c + Vector2(0, r * 0.34), r * 0.34, Color(0.30, 0.56, 0.40))
	draw_rect(Rect2(c.x - r * 0.14, c.y + r * 0.14, r * 0.28, r * 0.42), Color(0.24, 0.44, 0.32))
	# 头与帽檐
	draw_circle(c + Vector2(0, -r * 0.26), r * 0.24, Color(0.91, 0.80, 0.65))
	draw_arc(c + Vector2(0, -r * 0.34), r * 0.27, PI + 0.25, TAU - 0.25, 12,
		Color(0.38, 0.30, 0.22), 3.0)
	# 武器：第一件武器决定近战/远程造型
	var melee := true
	if u.weapons.size() > 0:
		melee = bool(u.weapons[0].melee)
	if melee:
		draw_line(c + Vector2(f * r * 0.22, r * 0.10), c + Vector2(f * r * 0.92, -r * 0.40),
			Color(0.78, 0.82, 0.86), 2.5)
		draw_line(c + Vector2(f * r * 0.30, r * 0.14), c + Vector2(f * r * 0.42, r * 0.00),
			Color(0.35, 0.26, 0.18), 3.0)
	else:
		draw_line(c + Vector2(f * r * 0.16, r * 0.08), c + Vector2(f * r * 0.86, r * 0.00),
			Color(0.24, 0.24, 0.27), 3.5)
		draw_circle(c + Vector2(f * r * 0.22, r * 0.12), r * 0.09, Color(0.55, 0.42, 0.28))


func _draw_creature(_u, c: Vector2, r: float, f: float) -> void:
	_draw_scorpion(c, r, f)


func _draw_scorpion(c: Vector2, r: float, f: float) -> void:
	var shell := Color(0.60, 0.40, 0.18)
	var body_r := r * 0.62
	# 腿
	for side in [-1, 1]:
		for i in 3:
			var base := c + Vector2(-f * body_r + f * body_r * 0.75 * float(i),
				float(side) * body_r * 0.25)
			draw_line(base, base + Vector2(-f * r * 0.30, float(side) * r * 0.42),
				Color(0.36, 0.24, 0.12), 2.0)
	# 尾巴：从背后卷到上方
	var tail := c + Vector2(-f * body_r * 0.95, body_r * 0.10)
	draw_polyline(PackedVector2Array([
		tail,
		tail + Vector2(-f * body_r * 0.55, -body_r * 0.55),
		tail + Vector2(-f * body_r * 0.85, -body_r * 1.15),
		tail + Vector2(-f * body_r * 0.45, -body_r * 1.55),
	]), shell.darkened(0.25), 3.5)
	draw_circle(tail + Vector2(-f * body_r * 0.30, -body_r * 1.65), r * 0.14,
		Color(0.92, 0.80, 0.35))
	# 身体
	_ellipse(c, body_r, body_r * 0.72, shell.darkened(0.30))
	_ellipse(c + Vector2(0, -r * 0.05), body_r * 0.86, body_r * 0.56, shell)
	# 甲片
	for i in 2:
		draw_line(c + Vector2(-body_r * 0.55, -body_r * 0.10 + body_r * 0.30 * float(i)),
			c + Vector2(body_r * 0.55, -body_r * 0.10 + body_r * 0.30 * float(i)),
			shell.lightened(0.35), 1.0)
	# 头部与双钳
	var head := c + Vector2(f * body_r * 0.90, 0)
	draw_circle(head, r * 0.26, shell.lightened(0.12))
	draw_circle(head + Vector2(f * r * 0.10, -r * 0.06), r * 0.06, Color(0.95, 0.30, 0.22))
	for side in [-1, 1]:
		var claw_base := c + Vector2(f * body_r * 0.72, float(side) * body_r * 0.40)
		draw_line(claw_base, claw_base + Vector2(f * r * 0.42, float(side) * r * 0.24),
			shell.darkened(0.20), 3.0)
		draw_circle(claw_base + Vector2(f * r * 0.46, float(side) * r * 0.26), r * 0.10,
			shell.lightened(0.10))


# -------------------- 底部提示 --------------------

func _draw_hint(font) -> void:
	if font == null:
		return
	draw_rect(Rect2(8, size.y - 24, 720, 18), Color(0, 0, 0, 0.45))
	draw_string(font, Vector2(14, size.y - 10),
		"未选武器：蓝框=可走 · 已选武器：红框=射程内、紫框=超程强攻 · 障碍物挡弹道（战车可轰碎，人物不行）",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.84, 0.80, 0.68))
