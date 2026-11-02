extends Node2D
## 红色战车行走体：8 帧横向条带（assets/vehicles/tank_walk.png，262×128/帧），底部对齐节点原点。
## 城镇 / 世界地图共用；调用 walk(dir) 连续播放，step_once(dir) 只播一遍。

const SHEET: Texture2D = preload("res://assets/vehicles/tank_walk.png")
const FRAMES := 8
const FPS := 9.0

@export var display_height := 52.0
@export var cast_shadow := true

var _sprite: Sprite2D
var _t := 0.0
var _playing := false
var _once := false
var _face := 1.0


func _ready() -> void:
	_sprite = Sprite2D.new()
	_sprite.texture = SHEET
	_sprite.hframes = FRAMES
	_sprite.vframes = 1
	_sprite.centered = true
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(_sprite)
	_apply_scale()
	_sprite.frame = 0


func _apply_scale() -> void:
	var fh := float(SHEET.get_height())
	var k := display_height / fh
	_sprite.scale = Vector2(k, k)
	# 让贴图底边落在节点原点（战车贴地）
	_sprite.offset = Vector2(0.0, -fh * 0.5)
	_sprite.flip_h = _face < 0


func set_dir(dir: Vector2) -> void:
	if absf(dir.x) < 0.01:
		return
	_face = 1.0 if dir.x > 0.0 else -1.0
	if _sprite != null:
		_sprite.flip_h = _face < 0


func walk(dir: Vector2) -> void:
	set_dir(dir)
	if not _playing:
		_playing = true
		_once = false


func step_once(dir: Vector2) -> void:
	set_dir(dir)
	_playing = true
	_once = true
	_t = 0.0
	if _sprite != null:
		_sprite.frame = 0


func idle() -> void:
	_playing = false
	_once = false
	_t = 0.0
	if _sprite != null:
		_sprite.frame = 0


func _process(delta: float) -> void:
	if not _playing:
		return
	_t += delta * FPS
	if _once and _t >= FRAMES:
		idle()
		return
	if _t >= FRAMES:
		_t = fmod(_t, FRAMES)
	if _sprite != null:
		_sprite.frame = int(_t)


func _draw() -> void:
	if not cast_shadow:
		return
	var r := display_height * 0.44
	draw_set_transform(Vector2(0.0, 0.0), 0.0, Vector2(1.0, 0.34))
	draw_circle(Vector2(0.0, 0.0), r, Color(0.10, 0.07, 0.05, 0.34))
