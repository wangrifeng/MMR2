extends RefCounted
## 野外规则：分区查询、地形准入、遭遇抽取。纯函数，场景与测试共用。

## 位置 → 分区行；不在任何分区里返回 {}。
## 城镇/基地/NPC 这类特殊格压在野外分区之上，优先返回。
static func zone_at(regions: Dictionary, tile: Vector2i) -> Dictionary:
	var fallback := {}
	for key in regions.keys():
		var row: Dictionary = regions[key]
		var r: Array = row.get("rect", [])
		if r.size() < 4:
			continue
		if tile.x >= int(r[0]) and tile.x < int(r[0]) + int(r[2]) \
			and tile.y >= int(r[1]) and tile.y < int(r[1]) + int(r[3]):
			if str(row.get("kind", "zone")) != "zone":
				return row
			if fallback.is_empty():
				fallback = row
	return fallback


## 底盘 terrain 列表是否允许进入该分区
static func passable(zone: Dictionary, terrain_list: Array) -> bool:
	if zone.is_empty():
		return false
	return terrain_list.has(str(zone.get("terrain", "")))


## 掷一次遭遇：返回敌人 id 数组，空数组 = 这一格安全
static func roll_encounter(zone: Dictionary, rng: RandomNumberGenerator) -> Array:
	var list: Array = zone.get("encounters", [])
	if list.is_empty():
		return []
	var chance := float(zone.get("encounter_chance", 0.0))
	if chance <= 0.0 or rng.randf() > chance:
		return []
	var total := 0
	for e in list:
		total += int(e.get("weight", 1))
	if total <= 0:
		return []
	var pick := rng.randi_range(0, total - 1)
	var acc := 0
	for e in list:
		acc += int(e.get("weight", 1))
		if pick < acc:
			var arr: Array = e.get("enemies", [])
			return arr.duplicate()
	return (list[0].get("enemies", []) as Array).duplicate()


## 世界地图起点格子
static func start_tile(world: Dictionary) -> Vector2i:
	var t: Array = world.get("start_tile", [1, 1])
	return Vector2i(int(t[0]), int(t[1]))
