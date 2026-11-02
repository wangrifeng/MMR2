extends Node
## 玩家运行时状态：现金、战车、部件拥有、背包、任务、赏金、存档。
## 存档粒度就是这里全部字段：现金 / 战车配置 / 已击杀赏金首 / 人物状态。

signal gold_changed(new_value: int)
signal vehicle_changed()
signal defeated_bounty(enemy_id: String)

const SAVE_PATH := "user://save.json"

const START_BUILD := {
	"chassis_id": "c_buggy", "engine_id": "e_small", "cunit_id": "cu_basic",
	"weapons": ["w_cannon75", "w_mg"],
}
const START_OWNED := ["c_buggy", "e_small", "cu_basic", "w_cannon75", "w_mg"]


# ---- 现金 ----
var gold: int = 500:
	set(value):
		gold = maxi(0, value)
		gold_changed.emit(gold)


# ---- 人物 ----
var player_hp: int = 40
var player_max_hp: int = 40

# ---- 小队：人物步行参战；extra_vehicles 是可选的附加战车（每项 {build, runtime}） ----
var characters: Array = []
var extra_vehicles: Array = []


# ---- 战车：当前改装方案 + 装甲实际值 + 武器剩余弹数 ----
var vehicle_build: Dictionary = START_BUILD.duplicate(true)
var vehicle_runtime: Dictionary = {}

# ---- 部件拥有制：只有买了的部件才能装 ----
var owned_parts: Array = START_OWNED.duplicate()

# ---- 背包：item id → 数量 ----
var inventory: Dictionary = {}

# ---- 任务：quest id → accepted / done；claimed 记录已领奖 ----
var quests: Dictionary = {}
var claimed: Dictionary = {}
var kill_counts: Dictionary = {}

# ---- 各类一次性标记（隐藏引擎、基地已清 等） ----
var flags: Dictionary = {}

# ---- 场景串联：野外/迷宫坐标 + 战斗结束后回到哪个场景 ----
var world_pos: Array = []
var maze_pos: Array = []
var return_scene: String = "res://scenes/world/world_scene.tscn"
var pending_battle_enemies: Array = []

# ---- 进度 ----
var defeated_bounties: Dictionary = {}
var cleared_terrain: Dictionary = {}


func reset_new_game() -> void:
	gold = 500
	player_hp = 40
	player_max_hp = 40
	characters = [_default_character()]
	extra_vehicles = []
	vehicle_build = START_BUILD.duplicate(true)
	vehicle_runtime = {}
	owned_parts = START_OWNED.duplicate()
	inventory = {}
	quests = {}
	claimed = {}
	kill_counts = {}
	flags = {}
	world_pos = []
	maze_pos = []
	return_scene = "res://scenes/world/world_scene.tscn"
	pending_battle_enemies = []
	defeated_bounties = {}
	cleared_terrain = {}
	init_runtime_from_build()


# ---- 便捷查询 ----
func vehicle_aromor_current() -> int:
	return int(vehicle_runtime.get("armor", 0))


func vehicle_armor_max() -> int:
	var gd := get_node("/root/GameData")
	return int(gd.chassis[vehicle_build.chassis_id].armor)


func vehicle_repair_cost() -> int:
	var gd := get_node("/root/GameData")
	var missing := vehicle_armor_max() - vehicle_aromor_current()
	return maxi(0, missing) * int(gd.balance.economy.repair_price_per_armor)


func chassis_terrain() -> Array:
	var gd := get_node("/root/GameData")
	return gd.chassis[vehicle_build.chassis_id].get("terrain", [])


func runtime_ready() -> void:
	## 战斗/野外前调：配置没变就保留战损与剩余弹药；换过底盘或武器才重建。
	if vehicle_runtime.is_empty():
		init_runtime_from_build()
		return
	var ids: Array = []
	for w in vehicle_runtime.weapons:
		ids.append(w.id)
	if ids != vehicle_build.weapons or int(vehicle_runtime.get("max_armor", 0)) != vehicle_armor_max():
		var keep_armor := mini(vehicle_aromor_current(), vehicle_armor_max())
		init_runtime_from_build()
		vehicle_runtime.armor = keep_armor


func init_runtime_from_build() -> void:
	## 战斗开始前调：根据 build 建一个独立于 build 的 runtime，里面存装甲/弹数的当前值。
	vehicle_runtime = runtime_from_build(vehicle_build, player_hp, player_max_hp)


func runtime_from_build(build: Dictionary, hp_value: int = -1, max_hp_value: int = -1) -> Dictionary:
	## 按任意改装方案生成一份运行时战损状态。主车与附加战车共用这套逻辑。
	var gd := get_node("/root/GameData")
	var c: Dictionary = gd.chassis[build.chassis_id]
	var out := {
		"armor": int(c.armor),
		"max_armor": int(c.armor),
		"hp": player_hp if hp_value < 0 else hp_value,
		"max_hp": player_max_hp if max_hp_value < 0 else max_hp_value,
	}
	out["weapons"] = []
	for wid in build.weapons:
		var w: Dictionary = gd.weapons[wid]
		out.weapons.append({
			"id": wid,
			"ammo": int(w.ammo),
			"max_ammo": int(w.ammo),
		})
	return out


func ensure_squad() -> void:
	if characters.is_empty():
		characters = [_default_character()]
	ensure_extra_runtimes()


func ensure_extra_runtimes() -> void:
	## 附加战车没打过仗时补一份满状态 runtime；只保留装甲与弹数，乘员按满血算。
	for entry in extra_vehicles:
		if entry.runtime.is_empty():
			entry.runtime = runtime_from_build(entry.build, player_max_hp, player_max_hp)


func refund_defeat() -> int:
	## 失败惩罚：扣 20% 现金 + 付修理费，返回扣掉的总额。
	var gd := get_node("/root/GameData")
	var bal: Dictionary = gd.balance
	var lost_gold := gold * int(bal.economy.defeat_gold_loss_rate * 100) / 100
	var repair := vehicle_repair_cost()
	gold -= lost_gold
	gold -= repair
	vehicle_runtime.armor = vehicle_armor_max()
	vehicle_runtime.hp = player_max_hp
	player_hp = player_max_hp
	_heal_characters()
	_heal_extra_vehicles()
	return lost_gold + repair


# ---------------- 部件拥有与商店 ----------------

func owns(part_id: String) -> bool:
	return owned_parts.has(part_id)


func owned_count(part_id: String) -> int:
	var n := 0
	for id in owned_parts:
		if id == part_id:
			n += 1
	return n


func parts_table(part_id: String) -> Dictionary:
	var gd := get_node("/root/GameData")
	for tbl in [gd.chassis, gd.engines, gd.cunits, gd.weapons]:
		if tbl.has(part_id):
			return tbl[part_id]
	return {}


func is_weapon(part_id: String) -> bool:
	var gd := get_node("/root/GameData")
	return gd.weapons.has(part_id)


func buy_part(part_id: String) -> Dictionary:
	var row := parts_table(part_id)
	if row.is_empty():
		return {"ok": false, "msg": "没有这个部件"}
	if not is_weapon(part_id) and owns(part_id):
		return {"ok": false, "msg": "已经拥有 %s" % row.name}
	var price := int(row.get("price", 0))
	if price <= 0:
		return {"ok": false, "msg": "%s 不出售" % row.name}
	if gold < price:
		return {"ok": false, "msg": "现金不够（还差 %dG）" % (price - gold)}
	gold -= price
	owned_parts.append(part_id)
	vehicle_changed.emit()
	return {"ok": true, "msg": "买下 %s，花掉 %dG" % [row.name, price], "cost": price}


func buy_item(item_id: String) -> Dictionary:
	var gd := get_node("/root/GameData")
	if not gd.items.has(item_id):
		return {"ok": false, "msg": "没有这个道具"}
	var row: Dictionary = gd.items[item_id]
	var price := int(row.get("price", 0))
	if gold < price:
		return {"ok": false, "msg": "现金不够（还差 %dG）" % (price - gold)}
	gold -= price
	inventory[item_id] = int(inventory.get(item_id, 0)) + 1
	return {"ok": true, "msg": "买下 %s，花掉 %dG" % [row.name, price], "cost": price}


func sell_scrap() -> Dictionary:
	var gd := get_node("/root/GameData")
	var qty := int(inventory.get("it_scrap", 0))
	if qty <= 0:
		return {"ok": false, "msg": "背包里没有废铁"}
	var gain := qty * int(gd.items["it_scrap"].sell_price)
	inventory.erase("it_scrap")
	gold += gain
	return {"ok": true, "msg": "卖掉 %d 块废铁，+%dG" % [qty, gain], "gain": gain}


func repair_vehicle() -> Dictionary:
	_ensure_runtime()
	var cost := vehicle_repair_cost()
	if cost <= 0:
		return {"ok": true, "msg": "装甲已经是满的", "cost": 0}
	if gold < cost:
		return {"ok": false, "msg": "现金不够（修理要 %dG）" % cost}
	gold -= cost
	vehicle_runtime.armor = vehicle_armor_max()
	vehicle_runtime.hp = player_max_hp
	player_hp = player_max_hp
	_heal_characters()
	_heal_extra_vehicles()
	vehicle_changed.emit()
	return {"ok": true, "msg": "装甲、乘员与同行猎人已修好，- %dG" % cost, "cost": cost}


func ammo_restock_cost() -> Dictionary:
	## 返回 {"cost": 总价, "detail": [{name, missing, price}]}
	_ensure_runtime()
	var gd := get_node("/root/GameData")
	var prices: Dictionary = gd.balance.economy.ammo_price
	var total := 0
	var detail: Array = []
	for w in vehicle_runtime.weapons:
		var row: Dictionary = gd.weapons[w.id]
		var missing := int(w.max_ammo) - int(w.ammo)
		if missing <= 0:
			continue
		var unit := int(prices.get(row.type, 0))
		var price := missing * unit
		total += price
		detail.append({"name": row.name, "missing": missing, "price": price})
	return {"cost": total, "detail": detail}


func restock_ammo() -> Dictionary:
	var info := ammo_restock_cost()
	var cost := int(info.cost)
	if cost <= 0:
		return {"ok": true, "msg": "弹药已经是满的", "cost": 0}
	if gold < cost:
		return {"ok": false, "msg": "现金不够（补给要 %dG）" % cost}
	gold -= cost
	for w in vehicle_runtime.weapons:
		w.ammo = int(w.max_ammo)
	return {"ok": true, "msg": "弹药补满，- %dG" % cost, "cost": cost}


# ---------------- 任务 ----------------

func accept_quest(quest_id: String) -> Dictionary:
	var gd := get_node("/root/GameData")
	if not gd.quests.has(quest_id):
		return {"ok": false, "msg": "没有这个任务"}
	if str(quests.get(quest_id, "")) == "done":
		return {"ok": false, "msg": "这个任务已经完成"}
	quests[quest_id] = "accepted"
	return {"ok": true, "msg": "接下「%s」" % gd.quests[quest_id].name}


func claim_quest(quest_id: String) -> Dictionary:
	var gd := get_node("/root/GameData")
	var row: Dictionary = gd.quests.get(quest_id, {})
	if row.is_empty():
		return {"ok": false, "msg": "没有这个任务"}
	if bool(claimed.get(quest_id, false)):
		return {"ok": false, "msg": "奖励已经领过了"}
	if str(row.type) == "bounty":
		if bool(defeated_bounties.get(row.target, false)):
			claimed[quest_id] = true
			quests[quest_id] = "done"
			return {"ok": true, "msg": "「%s」的赏金已由战斗结算" % row.name}
		return {"ok": false, "msg": "还没干掉目标"}
	var got := int(kill_counts.get(row.target, 0))
	var need := int(row.need)
	if got < need:
		return {"ok": false, "msg": "还差 %d 只（记录 %d / %d）" % [need - got, got, need]}
	var reward := int(row.reward)
	gold += reward
	claimed[quest_id] = true
	quests[quest_id] = "done"
	return {"ok": true, "msg": "交差完成，「%s」+%dG" % [row.name, reward], "gain": reward}


func deliver_quest(quest_id: String) -> Dictionary:
	var gd := get_node("/root/GameData")
	var row: Dictionary = gd.quests.get(quest_id, {})
	if row.is_empty() or str(row.type) != "side":
		return {"ok": false, "msg": "这里没有可交的货"}
	if str(quests.get(quest_id, "")) == "done":
		return {"ok": false, "msg": "「%s」已经交过了" % row.name}
	var item_id: String = row.target
	if int(inventory.get(item_id, 0)) < int(row.need):
		return {"ok": false, "msg": "需要先买一个 %s" % gd.items[item_id].name}
	inventory[item_id] = int(inventory.get(item_id, 0)) - int(row.need)
	var reward := int(row.reward)
	gold += reward
	quests[quest_id] = "done"
	claimed[quest_id] = true
	return {"ok": true, "msg": "机修工收下修理箱，+%dG" % reward, "gain": reward}


# ---------------- 存档 ----------------

func save_game() -> bool:
	var data := {
		"gold": gold,
		"player_hp": player_hp,
		"player_max_hp": player_max_hp,
		"vehicle_build": vehicle_build,
		"vehicle_runtime": vehicle_runtime,
		"characters": characters,
		"extra_vehicles": extra_vehicles,
		"owned_parts": owned_parts,
		"inventory": inventory,
		"quests": quests,
		"claimed": claimed,
		"kill_counts": kill_counts,
		"flags": flags,
		"defeated_bounties": defeated_bounties,
		"cleared_terrain": cleared_terrain,
		"world_pos": world_pos,
		"maze_pos": maze_pos,
		"return_scene": return_scene,
	}
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_error("存档写入失败：%s" % SAVE_PATH)
		return false
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	return true


func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)


func load_game() -> bool:
	if not has_save():
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	if parsed == null:
		push_error("存档解析失败：%s" % SAVE_PATH)
		return false
	var d: Dictionary = parsed
	reset_new_game()
	gold = int(d.get("gold", 500))
	player_hp = int(d.get("player_hp", 40))
	player_max_hp = int(d.get("player_max_hp", 40))
	characters = _normalize_characters(d.get("characters", []))
	extra_vehicles = _normalize_extra_vehicles(d.get("extra_vehicles", []))
	vehicle_build = _dict(d.get("vehicle_build", {}), START_BUILD.duplicate(true))
	owned_parts = _arr(d.get("owned_parts", []), START_OWNED.duplicate())
	inventory = _dict(d.get("inventory", {}), {})
	quests = _dict(d.get("quests", {}), {})
	claimed = _dict(d.get("claimed", {}), {})
	kill_counts = _dict(d.get("kill_counts", {}), {})
	flags = _dict(d.get("flags", {}), {})
	defeated_bounties = _dict(d.get("defeated_bounties", {}), {})
	cleared_terrain = _dict(d.get("cleared_terrain", {}), {})
	world_pos = _int_pair(d.get("world_pos", []))
	maze_pos = _int_pair(d.get("maze_pos", []))
	return_scene = str(d.get("return_scene", "res://scenes/world/world_scene.tscn"))
	var rt := _normalize_runtime(d.get("vehicle_runtime", {}))
	if rt.is_empty():
		init_runtime_from_build()
	else:
		vehicle_runtime = rt
	return true


func _normalize_characters(value: Variant) -> Array:
	var out: Array = []
	if value is Array:
		for c in value:
			if not (c is Dictionary):
				continue
			var max_hp := int(c.get("max_hp", 0))
			if max_hp <= 0:
				max_hp = int(_default_character().max_hp)
			out.append({
				"id": str(c.get("id", "p_hunter")),
				"hp": clampi(int(c.get("hp", max_hp)), 0, max_hp),
				"max_hp": max_hp,
			})
	if out.is_empty():
		out.append(_default_character())
	return out


func _normalize_extra_vehicles(value: Variant) -> Array:
	var out: Array = []
	if value is Array:
		for entry in value:
			if not (entry is Dictionary) or not (entry.get("build", null) is Dictionary):
				continue
			out.append({
				"build": (entry.build as Dictionary).duplicate(true),
				"runtime": _normalize_runtime(entry.get("runtime", {})),
			})
	return out


static func _normalize_runtime(value: Variant) -> Dictionary:
	if not (value is Dictionary):
		return {}
	var rt: Dictionary = (value as Dictionary).duplicate(true)
	rt["armor"] = int(rt.get("armor", 0))
	rt["max_armor"] = int(rt.get("max_armor", 0))
	rt["hp"] = int(rt.get("hp", 0))
	rt["max_hp"] = int(rt.get("max_hp", 0))
	var weapons: Array = []
	for w in rt.get("weapons", []):
		if w is Dictionary:
			weapons.append({
				"id": str(w.get("id", "")),
				"ammo": int(w.get("ammo", 0)),
				"max_ammo": int(w.get("max_ammo", 0)),
			})
	rt["weapons"] = weapons
	return rt


func _ensure_runtime() -> void:
	if vehicle_runtime.is_empty():
		init_runtime_from_build()


func _default_character() -> Dictionary:
	var hp := 40
	var gd := get_node_or_null("/root/GameData")
	if gd != null and gd.player.has("p_hunter"):
		hp = int(gd.player["p_hunter"].hp)
	return {"id": "p_hunter", "hp": hp, "max_hp": hp}


func _heal_characters() -> void:
	for c in characters:
		c.hp = int(c.max_hp)


func _heal_extra_vehicles() -> void:
	for entry in extra_vehicles:
		if entry.runtime.is_empty():
			continue
		entry.runtime.armor = int(entry.runtime.max_armor)
		entry.runtime.hp = int(entry.runtime.max_hp)


static func _dict(value: Variant, fallback: Dictionary) -> Dictionary:
	if value is Dictionary:
		return (value as Dictionary).duplicate(true)
	return fallback


static func _arr(value: Variant, fallback: Array) -> Array:
	if value is Array:
		return (value as Array).duplicate(true)
	return fallback


## JSON 里数字都是 float，坐标统一转回 int，避免 [20, 9] 比不过 [20.0, 9.0]
static func _int_pair(value: Variant) -> Array:
	if not (value is Array):
		return []
	var arr: Array = value
	if arr.size() < 2:
		return []
	return [int(arr[0]), int(arr[1])]
