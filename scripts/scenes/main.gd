extends Control
## M3 标题页：新游戏 / 继续游戏。进入后统一去城镇，由城镇串起改装→出战→回城。

const TOWN_SCENE := "res://scenes/world/town_scene.tscn"

var _info: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var title := Label.new()
	title.text = "废土猎人"
	title.add_theme_font_size_override("font_size", 40)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.anchor_left = 0; title.anchor_right = 1
	title.anchor_top = 0.16; title.anchor_bottom = 0.28
	add_child(title)

	var sub := Label.new()
	sub.text = "末日废土 · 战车改装 · 回合制 RPG（垂直切片）"
	sub.add_theme_font_size_override("font_size", 15)
	sub.modulate = Color(0.75, 0.8, 0.85)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.anchor_left = 0; sub.anchor_right = 1
	sub.anchor_top = 0.28; sub.anchor_bottom = 0.33
	add_child(sub)

	var box := VBoxContainer.new()
	box.anchor_left = 0.32; box.anchor_right = 0.68
	box.anchor_top = 0.40; box.anchor_bottom = 0.76
	box.add_theme_constant_override("separation", 12)
	add_child(box)

	var new_btn := Button.new()
	new_btn.text = "新游戏"
	new_btn.custom_minimum_size = Vector2(0, 44)
	new_btn.pressed.connect(_on_new_game)
	box.add_child(new_btn)

	var load_btn := Button.new()
	load_btn.text = "继续游戏（读取存档）"
	load_btn.custom_minimum_size = Vector2(0, 44)
	load_btn.disabled = not GameState.has_save()
	load_btn.pressed.connect(_on_load_game)
	box.add_child(load_btn)

	_info = Label.new()
	_info.add_theme_font_size_override("font_size", 13)
	_info.modulate = Color(0.75, 0.85, 1.0)
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info.anchor_left = 0.1; _info.anchor_right = 0.9
	_info.anchor_top = 0.78; _info.anchor_bottom = 0.92
	add_child(_info)

	_info.text = "从锈镇出发 → 改装厂 → 野外遭遇 → 回城换装。\n目标：攒钱换 105mm 主炮 / 中型引擎，然后去废弃军事基地干掉赏金首「天蝎」。"
	if not GameState.has_save():
		_info.text += "\n\n（还没有存档：新游戏后到城镇存档点保存）"


func _on_new_game() -> void:
	GameState.reset_new_game()
	GameState.return_scene = TOWN_SCENE
	get_tree().change_scene_to_file(TOWN_SCENE)


func _on_load_game() -> void:
	if not GameState.load_game():
		_info.text = "存档读取失败。"
		return
	GameState.return_scene = TOWN_SCENE
	get_tree().change_scene_to_file(TOWN_SCENE)
