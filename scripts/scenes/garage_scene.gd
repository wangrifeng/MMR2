extends Control
## M2 改装厂：底盘 / 引擎 / C 装置 / 武器选择，实时载重条 + GDD 4.2 三条校验。
## UI 用代码生成（和 battle_scene 保持一致），BattleController 不参与。

const Rules := preload("res://scripts/garage/garage_rules.gd")

const TOWN_SCENE := "res://scenes/world/town_scene.tscn"
const WORLD_SCENE := "res://scenes/world/world_scene.tscn"

## 三套标定配置（GDD 4.2 表格），用于自检与演示
const PRESETS := [
	{
		"label": "初始吉普",
		"note": "815 / 900 · 机动 22 · 可出车",
		"build": {
			"chassis_id": "c_buggy", "engine_id": "e_small", "cunit_id": "cu_basic",
			"weapons": ["w_cannon75", "w_mg"],
		},
	},
	{
		"label": "装甲卡车（超载）",
		"note": "1560 / 1500 · 超载 60 · 必须换引擎或卸 SE",
		"build": {
			"chassis_id": "c_truck", "engine_id": "e_mid", "cunit_id": "cu_basic",
			"weapons": ["w_cannon105", "w_vulcan", "w_missile"],
		},
	},
	{
		"label": "重装坦克",
		"note": "2270 / 2400 · 机动 21 · 装不下 SE",
		"build": {
			"chassis_id": "c_tank", "engine_id": "e_heavy", "cunit_id": "cu_hunter",
			"weapons": ["w_railgun", "w_gatling"],
		},
	},
]

var _gd: Node
var _gs: Node
var _tables: Dictionary
var _build: Dictionary

var _gold_label: Label
var _load_label: Label
var _speed_label: Label
var _load_bar: ProgressBar
var _check_labels: Dictionary = {}
var _type_headers: Dictionary = {}
var _weapon_box: VBoxContainer
var _hint: Label
var _sortie_btn: Button
var _part_buttons: Dictionary = {}


func _ready() -> void:
	_gd = get_node("/root/GameData")
	_gs = get_node("/root/GameState")
	_tables = {
		"chassis": _gd.chassis,
		"engines": _gd.engines,
		"cunits": _gd.cunits,
		"weapons": _gd.weapons,
		"balance": _gd.balance,
	}
	_build = _gs.vehicle_build.duplicate(true)
	_build_ui()
	_refresh()


# -------------------- UI 构建 --------------------

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	# 顶栏
	var top := HBoxContainer.new()
	top.anchor_top = 0.01; top.anchor_bottom = 0.06
	top.anchor_left = 0.02; top.anchor_right = 0.98
	add_child(top)

	var title := Label.new()
	title.text = "改装厂"
	title.add_theme_font_size_override("font_size", 26)
	top.add_child(title)

	_gold_label = _small_label(14)
	top.add_child(_gold_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(spacer)

	_load_label = _small_label(16)
	top.add_child(_load_label)

	_speed_label = _small_label(16)
	top.add_child(_speed_label)

	# 载重条
	_load_bar = ProgressBar.new()
	_load_bar.anchor_top = 0.065; _load_bar.anchor_bottom = 0.09
	_load_bar.anchor_left = 0.02; _load_bar.anchor_right = 0.98
	_load_bar.show_percentage = false
	_load_bar.max_value = 900
	add_child(_load_bar)

	# 中栏
	var mid := HBoxContainer.new()
	mid.anchor_top = 0.11; mid.anchor_bottom = 0.76
	mid.anchor_left = 0.02; mid.anchor_right = 0.98
	mid.add_theme_constant_override("separation", 14)
	add_child(mid)

	mid.add_child(_build_parts_panel())
	mid.add_child(_build_weapon_panel())
	mid.add_child(_build_check_panel())

	# 底栏说明
	_hint = Label.new()
	_hint.anchor_top = 0.78; _hint.anchor_bottom = 0.97
	_hint.anchor_left = 0.02; _hint.anchor_right = 0.98
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.add_theme_font_size_override("font_size", 13)
	_hint.modulate = Color(0.75, 0.85, 1.0)
	_hint.text = "选部件看载重变化；红色 = 违反规则，不能出车。"
	add_child(_hint)


func _build_parts_panel() -> VBoxContainer:
	var panel := VBoxContainer.new()
	panel.custom_minimum_size = Vector2(300, 0)
	panel.add_theme_constant_override("separation", 6)

	panel.add_child(_section_title("底盘"))
	var g1 := ButtonGroup.new()
	for cid in _gd.chassis.keys():
		var row: Dictionary = _gd.chassis[cid]
		var b := _part_button(_chassis_text(row) + _owned_suffix(cid), "chassis:%s" % cid, g1)
		panel.add_child(b)

	panel.add_child(_section_title("引擎"))
	var g2 := ButtonGroup.new()
	for eid in _gd.engines.keys():
		var row: Dictionary = _gd.engines[eid]
		var suffix := "" if bool(row.get("can_buy", true)) else "（掉落限定）"
		var b := _part_button("%s  出力%d 重%d%s%s" % [row.name, int(row.output), int(row.weight), suffix, _owned_suffix(eid)],
			"engine:%s" % eid, g2)
		panel.add_child(b)

	panel.add_child(_section_title("C 装置"))
	var g3 := ButtonGroup.new()
	for uid in _gd.cunits.keys():
		var row: Dictionary = _gd.cunits[uid]
		var b := _part_button("%s  命中+%d 回避+%d 重%d%s" % [row.name, int(row.acc_bonus), int(row.eva_bonus), int(row.weight), _owned_suffix(uid)],
			"cunit:%s" % uid, g3)
		panel.add_child(b)

	return panel


func _owned_suffix(id: String) -> String:
	return "" if _gs.owns(id) else "  （未拥有）"


func _build_weapon_panel() -> VBoxContainer:
	var panel := VBoxContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", 6)
	panel.add_child(_section_title("武器（按槽位类型）"))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)

	_weapon_box = VBoxContainer.new()
	_weapon_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_weapon_box.add_theme_constant_override("separation", 8)
	scroll.add_child(_weapon_box)

	return panel


func _build_check_panel() -> VBoxContainer:
	var panel := VBoxContainer.new()
	panel.custom_minimum_size = Vector2(300, 0)
	panel.add_theme_constant_override("separation", 8)

	panel.add_child(_section_title("出车校验"))

	for key in ["count", "size", "load"]:
		var row := Label.new()
		row.add_theme_font_size_override("font_size", 14)
		row.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_check_labels[key] = row
		panel.add_child(row)

	panel.add_child(_section_title("标定配置"))

	for preset in PRESETS:
		var b := Button.new()
		b.text = "%s\n%s" % [preset.label, preset.note]
		b.custom_minimum_size = Vector2(0, 46)
		b.pressed.connect(_apply_preset.bind(preset))
		panel.add_child(b)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 6)
	panel.add_child(actions)

	var save := Button.new()
	save.text = "保存方案"
	save.pressed.connect(_on_save)
	actions.add_child(save)

	_sortie_btn = Button.new()
	_sortie_btn.text = "出车 ▶"
	_sortie_btn.pressed.connect(_on_sortie)
	actions.add_child(_sortie_btn)

	var back := Button.new()
	back.text = "返回城镇（ESC）"
	back.pressed.connect(_back_to_main)
	panel.add_child(back)

	return panel


func _section_title(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 16)
	l.modulate = Color(0.95, 0.9, 0.7)
	return l


func _small_label(size: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.custom_minimum_size = Vector2(0, 0)
	return l


func _part_button(text: String, key: String, group: ButtonGroup) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.button_group = group
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size = Vector2(0, 26)
	b.pressed.connect(_on_part_picked.bind(key))
	_part_buttons[key] = b
	return b


func _chassis_text(row: Dictionary) -> String:
	var slot_desc: Array = []
	var counts := {}
	for slot in row.slots:
		counts[slot.type] = int(counts.get(slot.type, 0)) + 1
	for t in Rules.TYPES:
		if counts.has(t):
			slot_desc.append("%s×%d" % [Rules.TYPE_LABELS[t], int(counts[t])])
	return "%s  装甲%d 自重%d  %s" % [
		row.name, int(row.armor), int(row.weight), " ".join(slot_desc),
	]


# -------------------- 交互 --------------------

func _on_part_picked(key: String) -> void:
	var parts := key.split(":")
	var kind := parts[0]
	var id := parts[1]
	if not _gs.owns(id):
		_set_hint("%s 还没买（去镇上武器店购买后再装）。" % _part_name(id))
		return
	match kind:
		"chassis":
			_build.chassis_id = id
			var row: Dictionary = _gd.chassis[id]
			_set_hint("%s：%s" % [row.name, row.desc])
		"engine":
			_build.engine_id = id
			_set_hint("%s：%s" % [_gd.engines[id].name, _gd.engines[id].desc])
		"cunit":
			_build.cunit_id = id
			_set_hint("%s：%s" % [_gd.cunits[id].name, _gd.cunits[id].desc])
	_refresh()


func _part_name(id: String) -> String:
	var row: Dictionary = _gs.parts_table(id)
	return str(row.get("name", id))


func _equip(weapon_id: String) -> void:
	if _build.weapons.count(weapon_id) >= _gs.owned_count(weapon_id):
		_set_hint("部件库里没有更多「%s」了（去武器店再买一门）。" % _gd.weapons[weapon_id].name)
		return
	_build.weapons.append(weapon_id)
	_set_hint("%s：%s" % [_gd.weapons[weapon_id].name, _gd.weapons[weapon_id].desc])
	_refresh()


func _unequip(weapon_id: String) -> void:
	var idx: int = _build.weapons.find(weapon_id)
	if idx >= 0:
		_build.weapons.remove_at(idx)
	_refresh()


func _apply_preset(preset: Dictionary) -> void:
	_build = preset.build.duplicate(true)
	_set_hint("已套用「%s」：%s" % [preset.label, preset.note])
	_refresh()


func _on_save() -> void:
	var eval := _evaluate()
	_gs.vehicle_build = _build.duplicate(true)
	_gs.runtime_ready()
	_set_hint("方案已保存（%s）。%s" % [
		"可出车" if bool(eval.ok) else "仍未通过校验，出车时会失败",
		"载重 %d / %d · 机动 %d" % [int(eval.total_weight), int(eval.output), int(eval.speed)],
	])


func _on_sortie() -> void:
	var eval := _evaluate()
	if not bool(eval.ok):
		_set_hint("还不能出车：%s" % _fail_summary(eval))
		return
	_gs.vehicle_build = _build.duplicate(true)
	_gs.runtime_ready()
	_gs.pending_battle_enemies = []
	_gs.return_scene = WORLD_SCENE
	get_tree().change_scene_to_file(WORLD_SCENE)


func _back_to_main() -> void:
	_gs.return_scene = TOWN_SCENE
	get_tree().change_scene_to_file(TOWN_SCENE)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_back_to_main()


# -------------------- 刷新 --------------------

func _evaluate() -> Dictionary:
	return Rules.evaluate(_build, _tables)


func _refresh() -> void:
	var eval := _evaluate()

	# 部件选中态
	for key in _part_buttons.keys():
		var b: Button = _part_buttons[key]
		var parts: Array = key.split(":")
		var current := ""
		match parts[0]:
			"chassis": current = _build.chassis_id
			"engine": current = _build.engine_id
			"cunit": current = _build.cunit_id
		b.button_pressed = parts[1] == current

	# 顶栏数字
	_gold_label.text = "现金 %dG" % _gs.gold
	var total := int(eval.total_weight)
	var output := int(eval.output)
	var over := int(eval.overload)
	_load_label.text = "载重 %d / %d" % [total, output]
	_load_label.modulate = Color(1.0, 0.35, 0.35) if over > 0 else Color(0.65, 1.0, 0.7)
	_speed_label.text = "机动 %d%s" % [int(eval.speed), "" if over == 0 else "（超载）"]
	_speed_label.modulate = _load_label.modulate

	_load_bar.max_value = maxi(total, output)
	_load_bar.value = total
	_load_bar.modulate = Color(1.0, 0.4, 0.4) if over > 0 else Color(0.4, 0.85, 0.55)

	# 校验清单
	for check in eval.checks:
		var l: Label = _check_labels[check.key]
		l.text = "%s  %s · %s" % [
			"[通过]" if bool(check.ok) else "[不通过]",
			check.label, check.detail,
		]
		l.modulate = Color(0.6, 1.0, 0.65) if bool(check.ok) else Color(1.0, 0.45, 0.45)

	_sortie_btn.disabled = not bool(eval.ok)
	_sortie_btn.text = "出车 ▶" if bool(eval.ok) else "出车（校验未通过）"

	_rebuild_weapons(eval)


func _rebuild_weapons(eval: Dictionary) -> void:
	for c in _weapon_box.get_children():
		c.queue_free()
	_type_headers.clear()

	var chassis: Dictionary = _gd.chassis[_build.chassis_id]
	var type_status: Dictionary = eval.type_status

	for t in Rules.TYPES:
		var st: Dictionary = type_status[t]
		var header := Label.new()
		var suffix := ""
		if not bool(st.count_ok):
			suffix = "  超槽位"
		elif not bool(st.size_ok):
			suffix = "  尺寸不符"
		header.text = "%s  %d / %d%s" % [Rules.TYPE_LABELS[t], int(st.have), int(st.cap), suffix]
		header.add_theme_font_size_override("font_size", 15)
		var bad: bool = not bool(st.count_ok) or not bool(st.size_ok)
		header.modulate = Color(1.0, 0.5, 0.5) if bad else Color(0.9, 0.9, 0.85)
		_type_headers[t] = header
		_weapon_box.add_child(header)

		for wid in _gd.weapons.keys():
			var row: Dictionary = _gd.weapons[wid]
			if row.type != t:
				continue
			_weapon_box.add_child(_weapon_row(wid, row, chassis))


func _weapon_row(wid: String, row: Dictionary, chassis: Dictionary) -> HBoxContainer:
	var equipped: int = _build.weapons.count(wid)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)

	var fits: bool = Rules.fits_slot(row, chassis)
	var name_label := Label.new()
	name_label.text = row.name
	name_label.custom_minimum_size = Vector2(120, 0)
	name_label.add_theme_font_size_override("font_size", 13)
	hb.add_child(name_label)

	var stat := Label.new()
	stat.text = "%s · ATK%d · 命中%d · 弹%d · 重%d%s" % [
		row.size, int(row.atk), int(row.acc), int(row.ammo), int(row.weight),
		"  AOE" if bool(row.get("aoe", false)) else "",
	]
	stat.add_theme_font_size_override("font_size", 12)
	stat.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(stat)

	var count_label := Label.new()
	count_label.text = "×%d" % equipped
	count_label.custom_minimum_size = Vector2(34, 0)
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count_label.add_theme_font_size_override("font_size", 13)
	hb.add_child(count_label)

	var minus := Button.new()
	minus.text = "－"
	minus.custom_minimum_size = Vector2(30, 24)
	minus.disabled = equipped == 0
	minus.pressed.connect(_unequip.bind(wid))
	hb.add_child(minus)

	var plus := Button.new()
	plus.text = "＋"
	plus.custom_minimum_size = Vector2(30, 24)
	plus.disabled = equipped >= _gs.owned_count(wid)
	plus.pressed.connect(_equip.bind(wid))
	hb.add_child(plus)

	if _gs.owned_count(wid) <= 0:
		stat.text += "  未拥有（去武器店买）"
	if not fits:
		hb.modulate = Color(1.0, 0.5, 0.5)
		stat.text += "  放不进槽位"
	return hb


# -------------------- 小工具 --------------------

func _set_hint(text: String) -> void:
	_hint.text = text


func _fail_summary(eval: Dictionary) -> String:
	var parts: Array = []
	for check in eval.checks:
		if not bool(check.ok):
			parts.append("%s（%s）" % [check.label, check.detail])
	return "，".join(parts)
