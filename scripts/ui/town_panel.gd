extends Control
## 城镇设施面板：从可走城镇地图里走进建筑后弹出。
## 顶部可切换设施页（酒吧 / 修理厂 / 武器店 / 存档点 / 改装厂），底部关闭。
## 所有数值读写都走 GameState，界面只做展示与按钮。

const GARAGE_SCENE := "res://scenes/ui/garage_scene.tscn"

const SECTIONS := [
	["bar", "酒吧"],
	["repair", "修理厂"],
	["shop", "武器店"],
	["save", "存档点"],
	["garage", "改装厂"],
]

var _gd: Node
var _gs: Node
var _kind := "bar"
var _title := ""
var _on_close: Callable

var _title_label: Label
var _header: Label
var _tab_row: HBoxContainer
var _status: Label
var _body: VBoxContainer
var _built := false


func _ready() -> void:
	_gd = get_node("/root/GameData")
	_gs = get_node("/root/GameState")
	if _gs.vehicle_runtime.is_empty():
		_gs.init_runtime_from_build()
	_build()
	if not _title.is_empty():
		_refresh()


func open(kind: String, title: String, on_close: Callable) -> void:
	_kind = kind
	_title = title
	_on_close = on_close
	if _built:
		_refresh()


# -------------------- 骨架 --------------------

func _build() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var panel := PanelContainer.new()
	panel.anchor_left = 0.10; panel.anchor_right = 0.90
	panel.anchor_top = 0.06; panel.anchor_bottom = 0.94
	add_child(panel)

	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 8)
	panel.add_child(page)

	_title_label = Label.new()
	_title_label.add_theme_font_size_override("font_size", 22)
	page.add_child(_title_label)

	_header = Label.new()
	_header.add_theme_font_size_override("font_size", 13)
	_header.modulate = Color(0.72, 0.86, 1.0)
	page.add_child(_header)

	_tab_row = HBoxContainer.new()
	_tab_row.add_theme_constant_override("separation", 6)
	page.add_child(_tab_row)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 12)
	_status.modulate = Color(0.95, 0.85, 0.55)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(_status)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(scroll)

	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 5)
	scroll.add_child(_body)

	var bottom := HBoxContainer.new()
	bottom.alignment = BoxContainer.ALIGNMENT_END
	page.add_child(bottom)
	var close_btn := Button.new()
	close_btn.text = "离开（Esc）"
	close_btn.custom_minimum_size = Vector2(130, 28)
	close_btn.pressed.connect(_close)
	bottom.add_child(close_btn)

	_built = true


func _refresh() -> void:
	_title_label.text = _title
	var chassis: Dictionary = _gd.chassis[_gs.vehicle_build.chassis_id]
	_header.text = "现金 %dG   %s   装甲 %d/%d   乘员 HP %d/%d" % [
		_gs.gold, chassis.name,
		_gs.vehicle_aromor_current(), _gs.vehicle_armor_max(),
		_gs.player_hp, _gs.player_max_hp,
	]
	_status.text = ""
	for c in _tab_row.get_children():
		_tab_row.remove_child(c)
		c.queue_free()
	if _kind == "scrap":
		_tab_row.visible = false
	else:
		_tab_row.visible = true
		for entry in SECTIONS:
			var b := Button.new()
			b.text = str(entry[1])
			b.custom_minimum_size = Vector2(72, 26)
			b.disabled = str(entry[0]) == _kind
			var key := str(entry[0])
			b.pressed.connect(func(): _switch(key))
			_tab_row.add_child(b)
	_fill()


func _switch(kind: String) -> void:
	_kind = kind
	_refresh()


func _close() -> void:
	if _on_close.is_valid():
		_on_close.call()
	else:
		queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_close()


# -------------------- 内容 --------------------

func _fill() -> void:
	for c in _body.get_children():
		_body.remove_child(c)
		c.queue_free()
	match _kind:
		"bar": _fill_bar()
		"repair": _fill_repair()
		"shop": _fill_shop()
		"save": _fill_save()
		"garage": _fill_garage()
		"scrap": _fill_scrap()


func _fill_bar() -> void:
	_body.add_child(_section("赏金板"))
	for qid in _gd.quests.keys():
		_body.add_child(_quest_row(qid, _gd.quests[qid]))


func _quest_row(qid: String, row: Dictionary) -> HBoxContainer:
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)

	var name_l := Label.new()
	name_l.text = str(row.name)
	name_l.custom_minimum_size = Vector2(190, 0)
	name_l.add_theme_font_size_override("font_size", 13)
	hb.add_child(name_l)

	var desc := Label.new()
	desc.text = str(row.reward_desc)
	desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc.add_theme_font_size_override("font_size", 12)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hb.add_child(desc)

	var state := Label.new()
	state.custom_minimum_size = Vector2(140, 0)
	state.add_theme_font_size_override("font_size", 12)
	hb.add_child(state)

	var type := str(row.type)
	var target := str(row.target)
	var qstate := str(_gs.quests.get(qid, ""))
	if type == "bounty":
		var done: bool = bool(_gs.defeated_bounties.get(target, false))
		state.text = "已击杀（战斗结算）" if done else ("已接取" if qstate == "accepted" else "未接取")
		state.modulate = Color(0.6, 1.0, 0.65) if done else Color(0.9, 0.9, 0.8)
		if not done and qstate != "accepted":
			var b := Button.new()
			b.text = "接取"
			b.custom_minimum_size = Vector2(64, 24)
			b.pressed.connect(func(): _quest_action(qid, "accept"))
			hb.add_child(b)
	elif qstate == "done" or bool(_gs.claimed.get(qid, false)):
		state.text = "已完成"
		state.modulate = Color(0.6, 1.0, 0.65)
	elif type == "side" and str(row.target) == "it_repair":
		state.text = "去盐碱平原找机修工"
		state.modulate = Color(0.9, 0.85, 0.6)
	else:
		var got := int(_gs.kill_counts.get(target, 0))
		var need := int(row.need)
		state.text = "记录 %d / %d" % [got, need]
		var claim := Button.new()
		claim.text = "领奖 +%dG" % int(row.reward)
		claim.custom_minimum_size = Vector2(96, 24)
		claim.disabled = got < need
		claim.pressed.connect(func(): _quest_action(qid, "claim"))
		hb.add_child(claim)
	return hb


func _quest_action(qid: String, action: String) -> void:
	var res: Dictionary
	if action == "accept":
		res = _gs.accept_quest(qid)
	else:
		res = _gs.claim_quest(qid)
	_set_status(str(res.msg))
	_fill()


func _fill_repair() -> void:
	var cost: int = _gs.vehicle_repair_cost()
	var ammo: Dictionary = _gs.ammo_restock_cost()
	var ammo_cost := int(ammo.cost)
	var ammo_text := "弹药已满" if ammo_cost <= 0 else "补给弹药 %dG" % ammo_cost
	_body.add_child(_section("车间"))
	var l := Label.new()
	l.text = "装甲 %d/%d · 修理费 %dG（缺失装甲 × 3G）   ·   %s" % [
		_gs.vehicle_aromor_current(), _gs.vehicle_armor_max(), cost, ammo_text,
	]
	l.add_theme_font_size_override("font_size", 13)
	_body.add_child(l)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_body.add_child(row)
	row.add_child(_action_button("修理装甲 + 乘员 HP", _on_repair))
	row.add_child(_action_button("补给全部弹药", _on_restock))


func _fill_shop() -> void:
	var parts := [
		["底盘", _gd.chassis], ["引擎", _gd.engines],
		["C装置", _gd.cunits], ["武器", _gd.weapons],
	]
	for entry in parts:
		var group_name: String = entry[0]
		var tbl: Dictionary = entry[1]
		_body.add_child(_section("— %s —" % group_name))
		for pid in tbl.keys():
			_body.add_child(_shop_part_row(pid, tbl[pid]))

	_body.add_child(_section("— 道具 —"))
	for iid in _gd.items.keys():
		var row: Dictionary = _gd.items[iid]
		if int(row.get("price", 0)) <= 0:
			continue
		_body.add_child(_shop_item_row(iid, row))

	var scrap_row := HBoxContainer.new()
	scrap_row.add_theme_constant_override("separation", 8)
	var scrap_l := Label.new()
	scrap_l.text = "废铁 ×%d（收购价 %dG/块）" % [
		int(_gs.inventory.get("it_scrap", 0)), int(_gd.items["it_scrap"].sell_price)]
	scrap_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scrap_l.add_theme_font_size_override("font_size", 12)
	scrap_row.add_child(scrap_l)
	var sell_btn := Button.new()
	sell_btn.text = "全卖掉"
	sell_btn.custom_minimum_size = Vector2(80, 24)
	sell_btn.pressed.connect(_on_sell_scrap)
	scrap_row.add_child(sell_btn)
	_body.add_child(scrap_row)


func _shop_part_row(pid: String, row: Dictionary) -> HBoxContainer:
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)

	var name_l := Label.new()
	name_l.text = str(row.name)
	name_l.custom_minimum_size = Vector2(130, 0)
	name_l.add_theme_font_size_override("font_size", 12)
	hb.add_child(name_l)

	var detail := Label.new()
	var owned: int = _gs.owned_count(pid)
	detail.text = _part_detail(pid, row) + ("" if owned <= 0 else "  （已拥有 ×%d）" % owned)
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.add_theme_font_size_override("font_size", 11)
	hb.add_child(detail)

	var price := int(row.get("price", 0))
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(90, 24)
	if price <= 0:
		btn.text = "非卖品"
		btn.disabled = true
	elif not _gs.is_weapon(pid) and _gs.owns(pid):
		btn.text = "已拥有"
		btn.disabled = true
	else:
		btn.text = "买 %dG" % price
		btn.disabled = _gs.gold < price
		btn.pressed.connect(func(): _buy({"kind": "part", "id": pid}))
	hb.add_child(btn)
	return hb


func _part_detail(pid: String, row: Dictionary) -> String:
	if _gd.chassis.has(pid):
		return "装甲%d · 自重%d · %s" % [int(row.armor), int(row.weight), ", ".join(row.terrain)]
	if _gd.engines.has(pid):
		return "出力%d · 自重%d%s" % [int(row.output), int(row.weight),
			"" if bool(row.get("can_buy", true)) else " · 仅赏金掉落"]
	if _gd.cunits.has(pid):
		return "命中+%d · 回避+%d · 自重%d" % [int(row.acc_bonus), int(row.eva_bonus), int(row.weight)]
	return "%s · ATK%d · 命中%d · 弹%d · 重%d" % [
		str(row.size), int(row.atk), int(row.acc), int(row.ammo), int(row.weight)]


func _shop_item_row(iid: String, row: Dictionary) -> HBoxContainer:
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)

	var name_l := Label.new()
	name_l.text = str(row.name)
	name_l.custom_minimum_size = Vector2(130, 0)
	name_l.add_theme_font_size_override("font_size", 12)
	hb.add_child(name_l)

	var detail := Label.new()
	detail.text = "%s  （持有 %d）" % [str(row.desc), int(_gs.inventory.get(iid, 0))]
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.add_theme_font_size_override("font_size", 11)
	hb.add_child(detail)

	var price := int(row.get("price", 0))
	var btn := Button.new()
	btn.text = "买 %dG" % price
	btn.custom_minimum_size = Vector2(90, 24)
	btn.disabled = _gs.gold < price
	btn.pressed.connect(func(): _buy({"kind": "item", "id": iid}))
	hb.add_child(btn)
	return hb


func _fill_save() -> void:
	_body.add_child(_section("旧电台"))
	var l := Label.new()
	l.text = "存档：%s" % ("user://save.json（已存在）" if _gs.has_save() else "无存档")
	l.add_theme_font_size_override("font_size", 13)
	_body.add_child(l)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_body.add_child(row)
	row.add_child(_action_button("保存进度", _on_save))
	row.add_child(_action_button("读取存档", _on_load))


func _fill_garage() -> void:
	_body.add_child(_section("改装厂"))
	var l := Label.new()
	l.text = "底盘 / 引擎 / C装置 / 武器，全部在这里换。载重超了出不去。"
	l.add_theme_font_size_override("font_size", 13)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_child(l)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_body.add_child(row)
	row.add_child(_action_button("进入改装台", _on_garage))


func _fill_scrap() -> void:
	_body.add_child(_section("垃圾堆"))
	var l := Label.new()
	l.text = "半埋在地里的车壳、断掉的履带、一只不肯松口的机械狗下巴。翻一翻也许还能用。"
	l.add_theme_font_size_override("font_size", 13)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_child(l)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_body.add_child(row)
	row.add_child(_action_button("翻找废铁", _on_dig))


# -------------------- 动作 --------------------

func _buy(what: Dictionary) -> void:
	var res: Dictionary
	if str(what.kind) == "part":
		res = _gs.buy_part(str(what.id))
	else:
		res = _gs.buy_item(str(what.id))
	_set_status(str(res.msg))
	_fill()


func _on_repair() -> void:
	_set_status(str(_gs.repair_vehicle().msg))
	_fill()


func _on_restock() -> void:
	_set_status(str(_gs.restock_ammo().msg))
	_fill()


func _on_sell_scrap() -> void:
	_set_status(str(_gs.sell_scrap().msg))
	_fill()


func _on_save() -> void:
	if _gs.save_game():
		_set_status("已保存：现金、战车配置与弹数、已击杀赏金首、人物状态。")
	else:
		_set_status("存档写入失败（user://save.json）。")
	_fill()


func _on_load() -> void:
	if not _gs.has_save():
		_set_status("还没有存档。")
		return
	if _gs.load_game():
		_set_status("已读取存档。")
	else:
		_set_status("存档解析失败。")
	_fill()


func _on_garage() -> void:
	get_tree().change_scene_to_file(GARAGE_SCENE)


func _on_dig() -> void:
	if bool(_gs.cleared_terrain.get("town_scrap", false)):
		_set_status("已经翻干净了，只剩一地螺丝。")
		return
	_gs.cleared_terrain["town_scrap"] = true
	_gs.inventory["it_scrap"] = int(_gs.inventory.get("it_scrap", 0)) + 3
	_set_status("翻出 3 块废铁（回武器店可以卖）。")


# -------------------- 小工具 --------------------

func _section(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 16)
	l.modulate = Color(0.95, 0.9, 0.7)
	return l


func _action_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 28)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(cb)
	return b


func _set_status(text: String) -> void:
	_status.text = text
