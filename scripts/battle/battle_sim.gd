class_name BattleSim
extends RefCounted
## 一场战斗的完整结算（无人操作，双方自动出牌）。
## M0 用来跑数值，M1 的 BattleScene 直接复用这里的规则。

const BM := preload("res://scripts/battle/battle_math.gd")

const MAX_ROUNDS := 50


## 从改装方案构造玩家战车单位。
## build = { chassis_id, engine_id, cunit_id, weapons: [weapon_id...] }
static func make_player_unit(build: Dictionary, tables: Dictionary, balance: Dictionary) -> Dictionary:
	var chassis: Dictionary = tables.chassis[build.chassis_id]
	var engine: Dictionary = tables.engines[build.engine_id]
	var cunit: Dictionary = tables.cunits[build.cunit_id]
	var player: Dictionary = tables.player["p_hunter"]

	var total_weight := int(chassis.weight) + int(engine.weight) + int(cunit.weight)
	var weapons: Array = []
	for weapon_id in build.weapons:
		var weapon: Dictionary = tables.weapons[weapon_id]
		total_weight += int(weapon.weight)
		weapons.append(_weapon_state(weapon))

	return {
		"id": "player",
		"name": chassis.name,
		"is_player": true,
		"is_vehicle": true,
		"max_hp": int(player.hp),
		"hp": int(player.hp),
		"max_armor": int(chassis.armor),
		"armor": int(chassis.armor),
		"def": int(chassis.def),
		"acc_bonus": int(cunit.acc_bonus),
		"eva": int(cunit.eva_bonus),
		"speed": BM.speed(int(engine.output), total_weight, balance.speed),
		"total_weight": total_weight,
		"output": int(engine.output),
		"weapons": weapons,
		"alive": true,
	}


## 敌人统一用「一个武器」建模：atk / acc 来自敌人行，弹数无限。
static func make_enemy_unit(row: Dictionary) -> Dictionary:
	return {
		"id": row.id,
		"name": row.name,
		"is_player": false,
		"is_vehicle": bool(row.get("is_vehicle", false)),
		"max_hp": int(row.hp),
		"hp": int(row.hp),
		"max_armor": int(row.get("armor", 0)),
		"armor": int(row.get("armor", 0)),
		"def": int(row.def),
		"acc_bonus": 0,
		"eva": int(row.eva),
		"speed": int(row.spd),
		"weapons": [_weapon_state({
			"id": "natural", "name": row.name, "type": "main",
			"atk": row.atk, "acc": row.acc, "ammo": 999, "aoe": false,
		})],
		"ai": row.get("ai", "random"),
		"alive": true,
	}


static func run(
	player_build: Dictionary,
	enemy_ids: Array,
	tables: Dictionary,
	balance: Dictionary,
	rng: RandomNumberGenerator
) -> Dictionary:
	var player := make_player_unit(player_build, tables, balance)
	var enemies: Array = []
	for enemy_id in enemy_ids:
		enemies.append(make_enemy_unit(tables.enemies[enemy_id]))
	var units: Array = [player]
	units.append_array(enemies)

	var rounds := 0
	var won := false

	while rounds < MAX_ROUNDS:
		if _all_dead(enemies):
			won = true
			break
		if _player_defeated(player):
			break

		rounds += 1
		for unit in _turn_order(units, rng):
			if _all_dead(enemies):
				won = true
				break
			if _player_defeated(player):
				break
			if not bool(unit["alive"]):
				continue
			if bool(unit["is_player"]):
				_player_act(player, enemies, balance, rng)
			else:
				_enemy_act(unit, player, balance, rng)

	return {
		"win": won,
		"rounds": rounds,
		"timeout": rounds >= MAX_ROUNDS and not won and not _player_defeated(player),
		"armor_left": int(player["armor"]),
		"hp_left": int(player["hp"]),
		"player_speed": int(player["speed"]),
		"total_weight": int(player["total_weight"]),
		"output": int(player["output"]),
	}


static func _weapon_state(weapon: Dictionary) -> Dictionary:
	return {
		"id": weapon.id,
		"name": weapon.name,
		"type": weapon.type,
		"atk": int(weapon.atk),
		"acc": int(weapon.acc),
		"ammo": int(weapon.ammo),
		"aoe": bool(weapon.get("aoe", false)),
	}


## 装甲是纯吸收池：有甲先扣甲，溢出打 HP；HP 归零才算报废。
## 这样「有效血量 = armor + hp」才成立，敌方不会因为破甲就变成靶子。
static func _apply_damage(target: Dictionary, damage: int) -> void:
	var rest := damage
	if bool(target["is_vehicle"]):
		var absorbed := mini(int(target["armor"]), rest)
		target["armor"] = int(target["armor"]) - absorbed
		rest -= absorbed
	if rest > 0:
		target["hp"] = maxi(0, int(target["hp"]) - rest)
	if int(target["hp"]) <= 0:
		target["alive"] = false


static func _fire(
	attacker: Dictionary,
	weapon: Dictionary,
	target: Dictionary,
	balance: Dictionary,
	rng: RandomNumberGenerator
) -> void:
	weapon["ammo"] = int(weapon["ammo"]) - 1
	var hit := BM.hit_rate(int(weapon["acc"]), int(attacker["acc_bonus"]), int(target["eva"]), balance.combat)
	if rng.randf() > hit:
		return
	_apply_damage(target, BM.roll_damage(int(weapon["atk"]), int(target["def"]), balance.combat, rng))


## 玩家出牌策略：在「命中 × 期望伤害」最高的武器/目标组合上开火。
static func _player_act(
	player: Dictionary,
	enemies: Array,
	balance: Dictionary,
	rng: RandomNumberGenerator
) -> void:
	var best_score := -1.0
	var best_weapon := {}
	var best_target := {}
	for weapon in player["weapons"]:
		if int(weapon["ammo"]) <= 0:
			continue
		for target in enemies:
			if not bool(target["alive"]):
				continue
			var score := BM.hit_rate(
				int(weapon["acc"]), int(player["acc_bonus"]), int(target["eva"]), balance.combat
			) * BM.expected_damage(int(weapon["atk"]), int(target["def"]), balance.combat)
			if bool(weapon["aoe"]):
				score *= float(_alive_count(enemies))
			if score > best_score:
				best_score = score
				best_weapon = weapon
				best_target = target
	if best_weapon.is_empty():
		return
	_fire(player, best_weapon, best_target, balance, rng)


static func _enemy_act(
	enemy: Dictionary,
	player: Dictionary,
	balance: Dictionary,
	rng: RandomNumberGenerator
) -> void:
	var weapon: Dictionary = enemy["weapons"][0]
	if int(weapon["ammo"]) <= 0:
		return
	_fire(enemy, weapon, player, balance, rng)


static func _turn_order(units: Array, rng: RandomNumberGenerator) -> Array:
	var order: Array = []
	for unit in units:
		if bool(unit["alive"]):
			unit["tie"] = rng.randi_range(0, 999)
			order.append(unit)
	order.sort_custom(func(a, b): return int(a["speed"]) * 1000 + int(a["tie"]) > int(b["speed"]) * 1000 + int(b["tie"]))
	return order


static func _alive_count(units: Array) -> int:
	var count := 0
	for unit in units:
		if bool(unit["alive"]):
			count += 1
	return count


static func _all_dead(units: Array) -> bool:
	return _alive_count(units) == 0


static func _player_defeated(player: Dictionary) -> bool:
	return int(player["hp"]) <= 0
