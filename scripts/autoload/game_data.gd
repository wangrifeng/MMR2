extends Node
## 全局数据入口：所有场景通过 GameData.weapons["w_cannon75"] 这种形式取表。

const Loader := preload("res://scripts/data/data_loader.gd")

var balance: Dictionary
var chassis: Dictionary
var engines: Dictionary
var cunits: Dictionary
var weapons: Dictionary
var enemies: Dictionary
var items: Dictionary
var player: Dictionary
var quests: Dictionary
var regions: Dictionary         # 分区行（按 id 索引）
var regions_world: Dictionary   # 世界地图头信息（cols/rows/start_tile/步数间隔）
var maze: Dictionary            # 迷宫布局
var town_map: Dictionary        # 城镇格子地图（24×18 可走）


func _ready() -> void:
	reload()


func reload() -> void:
	var tables := Loader.load_all()
	balance = tables.balance
	chassis = tables.chassis
	engines = tables.engines
	cunits = tables.cunits
	weapons = tables.weapons
	enemies = tables.enemies
	items = tables.items
	player = tables.player
	quests = tables.quests
	regions = tables.regions
	regions_world = tables.regions_world
	maze = tables.maze
	town_map = tables.town_map
