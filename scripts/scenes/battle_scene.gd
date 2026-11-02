extends Control
## M4 战棋战斗场景：六边形棋盘 + 点击移动/攻击 + 武器射程高亮。
## BattleController 只负责逻辑，这里负责显示与输入。

const MAIN := "res://scenes/main/main.tscn"
const TOWN := "res://scenes/world/town_scene.tscn"
const CTRL := preload("res://scripts/battle/battle_controller.gd")
const Board := preload("res://scripts/battle/battle_board.gd")
const BM := preload("res://scripts/battle/battle_math.gd")
const BG := preload("res://assets/battle/bg_desert.png")

var _ctrl
var _gd: Node
var _gs: Node
var _defeated := false

var _round_label: Label
var _order_row: HBoxContainer
var _board

var _info_label: Label
var _status_label: Label
var _weapon_box: VBoxContainer
var _end_btn: Button
var _retreat_btn: Button

var _log: RichTextLabel

var _result_panel: PanelContainer
var _result_label: Label

var _selected_weapon_id: String = ""
var _sel_unit = null   # 右侧信息面板当前查看的单位，可以不是行动单位


func _ready() -> void:
	_gd = get_node("/root/GameData")
	_gs = get_node("/root/GameState")
	_build_ui()

	_ctrl = CTRL.new()
	add_child(_ctrl)
	_ctrl.turn_start.connect(_on_turn_start)
	_ctrl.player_needs_action.connect(_on_player_needs_action)
	_ctrl.state_changed.connect(_on_state_changed)
	_ctrl.attack_resolved.connect(_on_attack_resolved)
	_ctrl.unit_moved.connect(_on_unit_moved)
	_ctrl.unit_died.connect(_on_unit_died)
	_ctrl.logged.connect(_on_log)
	_ctrl.round_ended.connect(_on_round_ended)
	_ctrl.victory.connect(_on_victory)
	_ctrl.defeat.connect(_on_defeat)

	_ctrl.start(_gs.pending_battle_enemies)


# -------------------- UI 构建 --------------------

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_top_bar()
	_build_board()
	_build_side_panel()
	_build_result_panel()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


# -------------------- 背景绘制 --------------------

func _draw() -> void:
	var w := size.x
	var h := size.y
	if w <= 0.0 or h <= 0.0:
		return
	_draw_background(w, h)


func _draw_background(w: float, h: float) -> void:
	## 沙漠战场插画铺满窗口（按 cover 裁切，不拉伸变形），再压低四边保证棋盘可读。
	draw_rect(Rect2(0, 0, w, h), Color(0.09, 0.05, 0.03))
	var tex_size := BG.get_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return
	var cover := maxf(w / tex_size.x, h / tex_size.y)
	var draw_w := tex_size.x * cover
	var draw_h := tex_size.y * cover
	draw_texture_rect(BG,
		Rect2((w - draw_w) * 0.5, (h - draw_h) * 0.5, draw_w, draw_h), false)

	# 四边压暗 + 顶栏压暗，单位与文字叠在插画上仍然清楚
	for i in 8:
		var a := 0.30 * (1.0 - float(i) / 8.0)
		draw_rect(Rect2(0, 0, w, h * 0.055 * float(8 - i) / 8.0), Color(0.05, 0.03, 0.02, a))
		draw_rect(Rect2(0, h - h * 0.075 * float(8 - i) / 8.0, w, h * 0.075 * float(8 - i) / 8.0),
			Color(0.05, 0.03, 0.02, a))


func _build_top_bar() -> void:
	var top := HBoxContainer.new()
	top.anchor_top = 0.01; top.anchor_bottom = 0.055
	top.anchor_left = 0.02; top.anchor_right = 0.98
	add_child(top)

	_round_label = Label.new()
	_round_label.add_theme_font_size_override("font_size", 19)
	_round_label.text = "回合 0"
	top.add_child(_round_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(spacer)

	var order_title := Label.new()
	order_title.text = "行动顺序（机动降序）"
	order_title.add_theme_font_size_override("font_size", 13)
	top.add_child(order_title)

	_order_row = HBoxContainer.new()
	_order_row.add_theme_constant_override("separation", 8)
	top.add_child(_order_row)


func _build_board() -> void:
	_board = Board.new()
	_board.anchor_left = 0.015; _board.anchor_right = 0.70
	_board.anchor_top = 0.065; _board.anchor_bottom = 0.985
	_board.cell_clicked.connect(_on_cell_clicked)
	add_child(_board)


func _build_side_panel() -> void:
	var shell := PanelContainer.new()
	shell.anchor_left = 0.715; shell.anchor_right = 0.985
	shell.anchor_top = 0.065; shell.anchor_bottom = 0.985
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.055, 0.07, 0.86)
	sb.border_color = Color(0.36, 0.30, 0.22, 0.9)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(10)
	shell.add_theme_stylebox_override("panel", sb)
	add_child(shell)

	var panel := VBoxContainer.new()
	panel.add_theme_constant_override("separation", 6)
	shell.add_child(panel)

	_info_label = Label.new()
	_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_label.add_theme_font_size_override("font_size", 13)
	panel.add_child(_info_label)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.modulate = Color(0.95, 0.85, 0.55)
	panel.add_child(_status_label)

	panel.add_child(_section("武器"))
	_weapon_box = VBoxContainer.new()
	_weapon_box.add_theme_constant_override("separation", 3)
	panel.add_child(_weapon_box)

	_end_btn = Button.new()
	_end_btn.text = "结束我的回合"
	_end_btn.custom_minimum_size = Vector2(0, 30)
	_end_btn.pressed.connect(_on_end_turn)
	panel.add_child(_end_btn)

	_retreat_btn = Button.new()
	_retreat_btn.text = "撤退（退出战斗）"
	_retreat_btn.custom_minimum_size = Vector2(0, 30)
	_retreat_btn.add_theme_color_override("font_color", Color(1.0, 0.72, 0.62))
	_retreat_btn.pressed.connect(_on_retreat)
	panel.add_child(_retreat_btn)

	panel.add_child(_section("战斗记录"))
	_log = RichTextLabel.new()
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.add_theme_font_size_override("font_size", 12)
	_log.scroll_following = true
	panel.add_child(_log)


func _section(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 15)
	l.modulate = Color(0.95, 0.9, 0.7)
	return l


func _build_result_panel() -> void:
	_result_panel = PanelContainer.new()
	_result_panel.anchor_left = 0.30; _result_panel.anchor_right = 0.70
	_result_panel.anchor_top = 0.22; _result_panel.anchor_bottom = 0.80
	_result_panel.visible = false
	add_child(_result_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	_result_panel.add_child(box)

	_result_label = Label.new()
	_result_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_label.add_theme_font_size_override("font_size", 16)
	box.add_child(_result_label)

	var go := Button.new()
	go.text = "继续 ▶"
	go.custom_minimum_size = Vector2(0, 34)
	go.pressed.connect(_leave)
	box.add_child(go)


# -------------------- 刷新 --------------------

func _on_turn_start(unit, round_num: int) -> void:
	_selected_weapon_id = ""
	_sel_unit = unit
	_round_label.text = "回合 %d" % round_num
	_refresh_order(unit)
	_refresh_board()
	_refresh_info()
	if unit.is_player:
		_refresh_actions()
	else:
		_clear_actions()
		_status_label.text = "%s 正在行动..." % unit.label


func _on_player_needs_action(_unit) -> void:
	_refresh_actions()
	_status_label.text = "选择移动格，或直接选武器攻击。"


func _on_state_changed() -> void:
	if _sel_unit == null or not _sel_unit.is_alive():
		_sel_unit = _ctrl.active_unit
	_refresh_board()
	_refresh_info()
	if _ctrl.active_is_player():
		_refresh_actions()
	else:
		_clear_actions()


func _on_unit_moved(unit, from_cell: Vector2i, path: Array) -> void:
	_board.play_move(unit, from_cell, path)


func _on_attack_resolved(attacker, weapon: Dictionary, results: Array) -> void:
	_board.play_attack(attacker, weapon, results)
	_refresh_board()
	_refresh_info()


func _on_unit_died(_u) -> void:
	_refresh_board()
	_refresh_info()


func _on_round_ended(_n: int) -> void:
	pass


func _refresh_order(current) -> void:
	for c in _order_row.get_children():
		c.queue_free()
	var live: Array = []
	for u in _ctrl.units:
		if u.is_alive():
			live.append(u)
	live.sort_custom(func(a, b): return int(a.speed) > int(b.speed))
	for u in live:
		var tag := Label.new()
		tag.text = "%s %d" % [u.label.substr(0, 3), u.speed]
		tag.add_theme_font_size_override("font_size", 12)
		tag.modulate = Color(1.0, 0.9, 0.4) if u == current else (
			Color(0.6, 0.8, 1.0) if u.is_player else Color(0.9, 0.6, 0.6))
		_order_row.add_child(tag)


func _refresh_board() -> void:
	if _ctrl == null:
		return
	# 没选武器时只显示可走范围（蓝框）；选了武器就只显示武器射程（红/紫/橙框）
	var wid := _selected_weapon_id
	var reach: Dictionary = {} if not wid.is_empty() else _ctrl.reachable_cells()
	var attack: Dictionary = {}
	if _ctrl.active_is_player() and not wid.is_empty():
		attack = _ctrl.attack_cells(wid)
	_board.set_state(_ctrl.grid_cols, _ctrl.grid_rows, _ctrl.units,
		_ctrl.active_unit, reach, attack,
		_sel_unit if _sel_unit != _ctrl.active_unit else null, _ctrl.blocked)


func _refresh_info() -> void:
	var lines: Array = []
	var a = _sel_unit if _sel_unit != null else _ctrl.active_unit
	if a != null:
		var who := "我方" if a.is_player else "敌方"
		lines.append("%s · %s" % [a.label, who])
		lines.append("格子 (%d,%d)   机动 %d   MP %d/%d" % [
			a.cell.x, a.cell.y, a.speed, a.mp, a.max_mp])
		if a.is_vehicle:
			lines.append("装甲 %d/%d   HP %d/%d" % [a.armor, a.max_armor, a.hp, a.max_hp])
		else:
			lines.append("HP %d/%d" % [a.hp, a.max_hp])
		lines.append("防御 %d   回避 %d   武器 %d 件" % [a.def, a.eva, a.weapons.size()])
		if a == _ctrl.active_unit and _ctrl.active_is_player() and not a.has_acted:
			lines.append("▶ 当前行动单位，可以操作")
		elif a.is_player and a.has_acted:
			lines.append("（本回合已行动，仅查看）")
		else:
			lines.append("（仅查看，不能操作）")
	lines.append("")
	lines.append("我方小队：")
	for u in _ctrl.player_units:
		lines.append("  %s  HP %d/%d%s" % [
			u.label, u.hp, u.max_hp, "" if u.is_alive() else "（失去战斗力）"])
	if not _ctrl.enemies.is_empty():
		lines.append("敌方：")
		for u in _ctrl.enemies:
			lines.append("  %s  HP %d/%d%s" % [
				u.label, u.hp, u.max_hp, "" if u.is_alive() else "（已击毁）"])
	_info_label.text = "\n".join(lines)


func _clear_actions() -> void:
	for c in _weapon_box.get_children():
		c.queue_free()
	_end_btn.disabled = true


func _refresh_actions() -> void:
	for c in _weapon_box.get_children():
		c.queue_free()
	var unit = _ctrl.active_unit
	if unit == null or not unit.is_player or not _ctrl.active_is_player():
		_end_btn.disabled = true
		return
	_end_btn.disabled = false
	if unit.has_acted:
		_weapon_box.add_child(_hint("本回合已经行动过。点其他单位继续，或结束我的回合。"))
		return
	var cfg: Dictionary = _ctrl.balance.combat_v2
	if unit.has_moved:
		_weapon_box.add_child(_hint("已移动，剩余 MP %d。可以攻击，或结束我的回合。" % unit.mp))
	else:
		_weapon_box.add_child(_hint("移动点 %d：点蓝色格移动，或直接攻击。" % unit.mp))

	for w in unit.weapons:
		var rounds := BM.attack_rounds(unit.stats(), w, cfg)
		var count := BM.attack_count(unit.stats(), w, cfg)
		var tag := "近战" if bool(w.melee) else "射程 %d-%d（超程至 %d）" % [
			int(w.range_min), int(w.range_max), BM.max_attack_range(w, cfg)]
		var text := "%s  ·  %s  ·  %d回×%d次  ·  弹 %d/%d" % [
			w.name, tag, rounds, count, int(w.ammo), int(w.max_ammo)]
		if int(w.ammo) <= 0:
			text += "  （空）"
		var b := Button.new()
		b.text = text
		b.custom_minimum_size = Vector2(0, 27)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.disabled = int(w.ammo) <= 0
		if str(w.id) == _selected_weapon_id:
			b.modulate = Color(1.0, 0.9, 0.45)
		b.pressed.connect(_on_weapon_selected.bind(str(w.id)))
		_weapon_box.add_child(b)


func _hint(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", 11)
	l.modulate = Color(0.65, 0.85, 1.0)
	return l


# -------------------- 输入 --------------------

func _on_weapon_selected(weapon_id: String) -> void:
	# 再点一次已选中的武器 = 取消选择，回到显示可走范围
	if weapon_id == _selected_weapon_id:
		_selected_weapon_id = ""
		_refresh_board()
		_refresh_actions()
		_status_label.text = "已取消武器选择：蓝框内为可移动格。"
		return
	_selected_weapon_id = weapon_id
	_refresh_board()
	_refresh_actions()
	var mult := int(_ctrl.balance.combat_v2.overrange.range_multiplier)
	_status_label.text = "已选择武器：红格内为有效射程，紫格可超程强攻（最远 %d 倍射程，命中大降、不会暴击）。" % mult
	var unit = _ctrl.active_unit
	if unit != null and unit.is_vehicle:
		_status_label.text += " 橙边的障碍物可以轰碎。"


func _on_cell_clicked(cell: Vector2i) -> void:
	if _ctrl == null:
		return
	var target = _ctrl.unit_at(cell)
	var my_turn: bool = _ctrl.active_is_player()

	# 点我方单位：我的回合里直接切到它操作；非我方回合只查看信息
	if target != null and target.is_player:
		_sel_unit = target
		if my_turn and _ctrl.select_unit(target):
			_selected_weapon_id = ""
			_refresh_board()
			_refresh_actions()
			_refresh_info()
			_status_label.text = "已切换到 %s：点蓝格移动，或点敌人攻击。" % target.label
		else:
			_refresh_board()
			_refresh_info()
			if target.has_acted:
				_status_label.text = "%s 本回合已经行动过了，只能查看。" % target.label
			else:
				_status_label.text = "%s 只能查看，现在是敌方回合。" % target.label
		return

	if not my_turn:
		if target != null:
			_sel_unit = target
			_refresh_board()
			_refresh_info()
			_status_label.text = "现在不是你的回合，只能查看 %s。" % target.label
		else:
			_status_label.text = "现在不是你的回合。"
		return

	# 点到障碍物格：战车能轰碎，人物只会白打一发
	if target == null and _ctrl.blocked.has(cell):
		var rock_res: Dictionary = _attack_obstacle(cell)
		_status_label.text = str(rock_res.get("msg", ""))
		_selected_weapon_id = ""
		return

	if target != null and not target.is_player:
		var wid := _selected_weapon_id
		if wid.is_empty():
			wid = _auto_pick_weapon(target)
		if not wid.is_empty():
			var res: Dictionary = _ctrl.player_attack(wid, cell)
			if not bool(res.ok):
				_status_label.text = str(res.msg)
			_selected_weapon_id = ""
			return
		_sel_unit = target
		_refresh_board()
		_refresh_info()
		_status_label.text = "%s 不在当前武器射程内。" % target.label
		return

	_sel_unit = _ctrl.active_unit
	if _ctrl.player_move_to(cell):
		_selected_weapon_id = ""
		_refresh_board()
		_refresh_actions()
		_status_label.text = "移动完成。可以攻击，或结束我的回合。"
		return
	_status_label.text = "这个格子走不到（被占用或超出移动点）。"


func _auto_pick_weapon(target) -> String:
	var unit = _ctrl.active_unit
	if unit == null:
		return ""
	for w in unit.weapons:
		if int(w.ammo) > 0 and unit.can_hit(unit.cell, target, w, _ctrl.balance.combat_v2):
			return str(w.id)
	return ""


func _attack_obstacle(cell: Vector2i) -> Dictionary:
	## 点障碍物格：没选武器就自动挑一件能打到它的非近战武器。
	var unit = _ctrl.active_unit
	if unit == null:
		return {"ok": false, "msg": "现在没有可操作的单位"}
	if not _selected_weapon_id.is_empty():
		return _ctrl.player_attack(_selected_weapon_id, cell)
	var first_msg := ""
	for w in unit.weapons:
		if int(w.ammo) <= 0 or bool(w.melee):
			continue
		var res: Dictionary = _ctrl.player_attack(str(w.id), cell)
		if bool(res.ok):
			return {"ok": true, "msg": "已攻击障碍物。"}
		if first_msg.is_empty():
			first_msg = str(res.msg)
	return {"ok": false, "msg": first_msg if not first_msg.is_empty() \
		else "没有能打到障碍物的武器（先选一件远程武器）。"}


func _on_end_turn() -> void:
	_selected_weapon_id = ""
	_status_label.text = "结束我的回合，交给敌方行动……"
	_ctrl.end_turn()


# -------------------- 结算 --------------------

func _on_log(msg: String) -> void:
	_log.append_text(msg + "\n")


func _on_victory(summary: Dictionary) -> void:
	_refresh_board()
	_refresh_info()
	_clear_actions()
	var bounty_line := ""
	if not summary.bounties.is_empty():
		var row: Dictionary = _gd.enemies[summary.bounties[0]]
		bounty_line = "\n赏金首 %s +%dG" % [row.name, int(row.gold)]
	var drops_line := ""
	for d in summary.drops:
		if d.item == "e_scorpion":
			drops_line += "\n  掉落 「赤蝎」引擎（唯一掉落，无法购买）"
		else:
			var row: Dictionary = _gd.items.get(d.item, null)
			if row:
				drops_line += "\n  掉落 ×%d %s" % [d.qty, row.name]
	_result_label.text = "★ 胜利\n\n+%dG\n+%dEXP%s%s\n\n现金 %dG" % [
		summary.gold, summary.exp, bounty_line, drops_line, _gs.gold
	]
	_result_panel.visible = true


func _on_defeat(summary: Dictionary) -> void:
	_defeated = true
	_refresh_board()
	_refresh_info()
	_clear_actions()
	_result_label.text = "☠ 失败\n\n%s\n被最近城镇拖回，损失 %dG\n现金 %dG\n装甲与乘员已修复。" % [
		str(summary.get("reason", "")), int(summary.lost_gold), _gs.gold
	]
	_result_panel.visible = true


func _on_retreat() -> void:
	## 撤退：直接放弃这场遭遇，回到进战斗前的位置，不结算经验/金钱，也不算失败。
	if _result_panel.visible:
		return
	_gs.pending_battle_enemies = []
	var target: String = _gs.return_scene
	if target.is_empty():
		target = MAIN
	get_tree().change_scene_to_file(target)


func _leave() -> void:
	var target: String = TOWN if _defeated else _gs.return_scene
	if target.is_empty():
		target = MAIN
	get_tree().change_scene_to_file(target)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE \
			and _result_panel.visible:
		_leave()
