extends Node
## 六边形战棋回合循环。只负责逻辑与信号，不负责 UI。
## 每个单位按机动（speed）排序行动，一回合内可以移动 + 攻击一次。
## 武器射程决定攻击距离；melee=true 的武器只能打相邻格。
## 外部：battle_scene 创建 controller，监听信号，调用 player_move_to / player_attack / end_turn。

const BattleUnit := preload("res://scripts/battle/battle_unit.gd")
const AI := preload("res://scripts/battle/ai_controller.gd")
const Hex := preload("res://scripts/battle/hex_rules.gd")
const BM := preload("res://scripts/battle/battle_math.gd")

signal turn_start(unit, round_number: int)
signal player_needs_action(unit)
signal state_changed()
signal attack_resolved(attacker, weapon: Dictionary, results: Array)
signal unit_moved(unit, from_cell: Vector2i, path: Array)
signal unit_died(unit)
signal obstacle_destroyed(cell: Vector2i)
signal round_ended(round_number: int)
signal victory(summary: Dictionary)
signal defeat(summary: Dictionary)
signal logged(msg: String)

var _gd: Node
var _gs: Node
var balance: Dictionary

var player_units: Array = []
var enemies: Array = []
var units: Array = []
var active_unit = null
var phase: String = "idle"          # move / attack / done / idle
var round_number: int = 0

var grid_cols: int = 11
var grid_rows: int = 9
var blocked: Dictionary = {}
var max_rounds: int = 30

var rng: RandomNumberGenerator
var rng_seed: int = -1
## 测试/数值模拟用：为 true 时玩家单位也由 AI 托管，整场同步跑完。
var auto_player: bool = false

var _order: Array = []
var _enemy_idx: int = 0
var _finished: bool = false


func start(enemy_ids: Array) -> void:
	_gd = get_node("/root/GameData")
	_gs = get_node("/root/GameState")
	balance = _gd.balance
	rng = RandomNumberGenerator.new()
	if rng_seed >= 0:
		rng.seed = rng_seed
	else:
		rng.randomize()

	grid_cols = int(balance.battle.get("grid_cols", 11))
	grid_rows = int(balance.battle.get("grid_rows", 9))
	blocked = {}
	max_rounds = int(balance.battle.get("max_rounds", 30))

	_gs.runtime_ready()
	_gs.ensure_squad()

	_build_player_units()
	_build_enemy_units(enemy_ids)
	_assign_start_cells()
	_generate_obstacles()

	_log("=== 战斗开始 · %d 名敌人 ===" % enemies.size())
	_begin_round()


# -------------------- 建场 --------------------

func _build_player_units() -> void:
	var player_row: Dictionary = _gd.player["p_hunter"]
	var max_units := int(balance.battle.get("max_units_per_side", 4))

	var chassis: Dictionary = _gd.chassis[_gs.vehicle_build.chassis_id]
	var engine: Dictionary = _gd.engines[_gs.vehicle_build.engine_id]
	var cunit: Dictionary = _gd.cunits[_gs.vehicle_build.cunit_id]
	var main_u = BattleUnit.from_vehicle(_gs.vehicle_runtime, _gs.vehicle_build, chassis,
		engine, cunit, player_row, balance, _gd.weapons, str(chassis.name), -1)
	_attach(main_u)
	player_units.append(main_u)

	for i in _gs.extra_vehicles.size():
		if player_units.size() >= max_units:
			break
		var entry: Dictionary = _gs.extra_vehicles[i]
		var b: Dictionary = entry.build
		chassis = _gd.chassis[b.chassis_id]
		engine = _gd.engines[b.engine_id]
		cunit = _gd.cunits[b.cunit_id]
		var u = BattleUnit.from_vehicle(entry.runtime, b, chassis, engine, cunit,
			player_row, balance, _gd.weapons, "%s·僚车" % chassis.name, i)
		_attach(u)
		player_units.append(u)

	for i in _gs.characters.size():
		if player_units.size() >= max_units:
			break
		var ch: Dictionary = _gs.characters[i]
		if int(ch.get("hp", 0)) <= 0:
			continue
		var cu = BattleUnit.from_character(ch, player_row, balance, i)
		_attach(cu)
		player_units.append(cu)


func _build_enemy_units(enemy_ids: Array) -> void:
	var max_units := int(balance.battle.get("max_units_per_side", 4))
	for eid in enemy_ids:
		if enemies.size() >= max_units:
			break
		if not _gd.enemies.has(eid):
			continue
		var row: Dictionary = _gd.enemies[eid]
		var u = BattleUnit.from_enemy(row, balance)
		_attach(u)
		enemies.append(u)


func _attach(u) -> void:
	add_child(u)
	u.died.connect(_on_unit_died)
	units.append(u)


func _assign_start_cells() -> void:
	var player_col := int(balance.battle.get("player_start_col", 1))
	var enemy_col := int(balance.battle.get("enemy_start_col", 9))
	_place_units(player_units, player_col)
	_place_units(enemies, enemy_col)


func _place_units(group: Array, col: int) -> void:
	var rows := _spread_rows(group.size())
	for i in group.size():
		var cell := Vector2i(col, rows[i])
		if unit_at(cell) != null:
			cell = _nearest_free_cell(cell)
		group[i].cell = cell


func _spread_rows(count: int) -> Array:
	var center := int(grid_rows / 2)
	var offsets := [0, -1, 1, -2, 2, -3, 3]
	var out: Array = []
	for i in count:
		out.append(clampi(center + int(offsets[i % offsets.size()]), 0, grid_rows - 1))
	return out


func _nearest_free_cell(start: Vector2i) -> Vector2i:
	for r in range(grid_rows):
		for c in range(grid_cols):
			var cell := Vector2i(c, r)
			if unit_at(cell) == null:
				return cell
	return start


func _generate_obstacles() -> void:
	## 随机障碍物：只落在所有单位及其 clear_ring 圈之外，每场 min_count~max_count 个。
	## 抽取时按“离棋盘中心越近权重越高”加权，优先在中间生成。
	## 用自身 rng 逐个抽取，保证同种子可复现（不能用 Array.shuffle）。
	var cfg: Dictionary = balance.battle.get("obstacles", {})
	var ring := int(cfg.get("clear_ring", 1))
	var min_count := int(cfg.get("min_count", 1))
	var max_count := int(cfg.get("max_count", 5))
	var candidates: Array = []
	for x in grid_cols:
		for y in grid_rows:
			var cell := Vector2i(x, y)
			var keep_clear := false
			for u in units:
				if Hex.distance(cell, u.cell) <= ring:
					keep_clear = true
					break
			if not keep_clear:
				candidates.append(cell)
	if candidates.is_empty():
		return
	var center := Vector2i(int(grid_cols / 2), int(grid_rows / 2))
	var max_dist := 0
	for cell in candidates:
		max_dist = maxi(max_dist, Hex.distance(cell, center))
	var count := mini(rng.randi_range(min_count, max_count), candidates.size())
	# 优先中间：先在离中心最近的一半范围内抽，抽不满再逐圈向外放宽
	var radius := max_dist / 2
	var placed := 0
	while placed < count:
		var pool: Array = []
		for cell in candidates:
			if Hex.distance(cell, center) <= radius:
				pool.append(cell)
		while not pool.is_empty() and placed < count:
			var idx := rng.randi_range(0, pool.size() - 1)
			blocked[pool[idx]] = true
			candidates.erase(pool[idx])
			pool.remove_at(idx)
			placed += 1
		if radius >= max_dist:
			break
		radius += 1


# -------------------- 回合循环 --------------------

func _begin_round() -> void:
	if _finished:
		return
	round_number += 1
	if round_number > max_rounds:
		_log("超过 %d 回合，撤退" % max_rounds)
		_on_defeat("回合上限")
		return
	# 我方整回合：所有存活单位都恢复 MP 与行动机会
	for u in player_units:
		if u.is_alive():
			u.begin_activation()
	# 敌方同一回合内按机动排序依次行动
	_order.clear()
	for u in enemies:
		if u.is_alive():
			u.tie = rng.randi_range(0, 999)
			_order.append(u)
	_order.sort_custom(func(a, b):
		return int(a.speed) * 1000 + int(a.tie) > int(b.speed) * 1000 + int(b.tie))
	_enemy_idx = 0
	if round_number > 1:
		round_ended.emit(round_number - 1)
	_start_player_phase()


func _start_player_phase() -> void:
	if _finished:
		return
	phase = "player"
	if auto_player:
		for u in player_units:
			if _finished:
				return
			if not u.is_alive():
				continue
			u.begin_activation()
			active_unit = u
			AI.take_turn(self, u)
			if _check_end():
				return
		_start_enemy_phase()
		return
	active_unit = _next_player_unit()
	if active_unit == null:
		_start_enemy_phase()
		return
	turn_start.emit(active_unit, round_number)
	state_changed.emit()
	player_needs_action.emit(active_unit)


func _next_player_unit():
	for u in player_units:
		if u.is_alive() and not u.has_acted:
			return u
	return null


func _start_enemy_phase() -> void:
	if _finished:
		return
	phase = "enemy"
	active_unit = null
	state_changed.emit()
	while _enemy_idx < _order.size():
		if _finished:
			return
		var u = _order[_enemy_idx]
		_enemy_idx += 1
		if not u.is_alive():
			continue
		active_unit = u
		u.begin_activation()
		turn_start.emit(u, round_number)
		AI.take_turn(self, u)
		if _check_end():
			return
	active_unit = null
	_begin_round()


# -------------------- 玩家操作 --------------------

func active_is_player() -> bool:
	return not _finished and phase == "player" and active_unit != null \
		and active_unit.is_alive()


func can_control(unit) -> bool:
	return active_is_player() and unit != null and unit.is_player and unit.is_alive() \
		and not unit.has_acted


func select_unit(unit) -> bool:
	## 我方回合内随时切换要操作的单位；已经行动过的单位只能看信息。
	if not can_control(unit):
		return false
	if unit == active_unit:
		return true
	active_unit = unit
	turn_start.emit(unit, round_number)
	state_changed.emit()
	player_needs_action.emit(unit)
	return true


func foes_of(unit) -> Array:
	if unit == null:
		return []
	return enemies if unit.is_player else player_units


func unit_at(cell: Vector2i):
	for u in units:
		if u.is_alive() and u.cell == cell:
			return u
	return null


func occupied_cells(exclude = null) -> Dictionary:
	var out: Dictionary = {}
	for u in units:
		if u.is_alive() and u != exclude:
			out[u.cell] = true
	return out


func reachable_for(unit) -> Dictionary:
	return Hex.reachable(unit.cell, unit.mp, grid_cols, grid_rows, blocked,
		occupied_cells(unit))


func reachable_cells() -> Dictionary:
	if not can_control(active_unit) or active_unit.has_moved:
		return {}
	return reachable_for(active_unit)


func player_move_to(cell: Vector2i) -> bool:
	if not can_control(active_unit) or active_unit.has_moved:
		return false
	if occupied_cells(active_unit).has(cell):
		return false
	var path: Array = Hex.path(active_unit.cell, cell, active_unit.mp, grid_cols, grid_rows,
		blocked, occupied_cells(active_unit))
	if path.is_empty():
		return false
	var from_cell: Vector2i = active_unit.cell
	active_unit.cell = cell
	active_unit.mp -= path.size()
	active_unit.has_moved = true
	state_changed.emit()
	unit_moved.emit(active_unit, from_cell, path)
	return true


func weapon_targets(weapon: Dictionary) -> Array:
	if not can_control(active_unit):
		return []
	var out: Array = []
	for e in enemies:
		if e.is_alive() and active_unit.can_hit(active_unit.cell, e, weapon, balance.combat_v2):
			out.append(e)
	return out


func weapon_has_targets(weapon: Dictionary) -> bool:
	return not weapon_targets(weapon).is_empty()


func attack_cells(weapon_id: String) -> Dictionary:
	## 返回 {cell: "in"/"over"/"rock"}：红色=射程内，紫色=超程强攻（最远 range_max×2，命中大降、必定不暴击），
	## 橙色=可轰碎的障碍物格（只有战车能打碎）。
	if not can_control(active_unit):
		return {}
	var weapon := _find_weapon(active_unit, weapon_id)
	if weapon == null:
		return {}
	var out: Dictionary = {}
	for cell in Hex.cells_in_range(active_unit.cell, int(weapon.range_min), int(weapon.range_max),
			grid_cols, grid_rows):
		out[cell] = "in"
	if not bool(weapon.melee):
		for cell in Hex.cells_in_range(active_unit.cell, int(weapon.range_max) + 1,
				BM.max_attack_range(weapon, balance.combat_v2), grid_cols, grid_rows):
			out[cell] = "over"
	if active_unit.is_vehicle:
		var reach := BM.max_attack_range(weapon, balance.combat_v2)
		for cell in blocked.keys():
			var dist := Hex.distance(active_unit.cell, cell)
			if dist < int(weapon.range_min) or dist > reach:
				continue
			# 中间还隔着别的障碍物时打不到，不标可攻击
			if Hex.first_blocker(active_unit.cell, cell, blocked).x >= 0:
				continue
			out[cell] = "rock"
	return out


func player_attack(weapon_id: String, target_cell: Vector2i) -> Dictionary:
	if not active_is_player():
		return {"ok": false, "msg": "现在不是你的回合"}
	if active_unit.has_acted:
		return {"ok": false, "msg": "%s 本回合已经行动过了" % active_unit.label}
	var weapon = _find_weapon(active_unit, weapon_id)
	if weapon == null:
		return {"ok": false, "msg": "没有这件武器"}
	if int(weapon.ammo) <= 0:
		return {"ok": false, "msg": "弹药打光了"}
	var target = unit_at(target_cell)
	if target == null:
		if blocked.has(target_cell):
			return _smash_obstacle(weapon, target_cell)
		return {"ok": false, "msg": "目标格没有敌人"}
	if target.is_player == active_unit.is_player:
		return {"ok": false, "msg": "目标格没有敌人"}
	if not active_unit.can_hit(active_unit.cell, target, weapon, balance.combat_v2):
		return {"ok": false, "msg": "目标不在 %s 的射程内" % weapon.name}
	var results := _execute_attack(active_unit, weapon, target)
	active_unit.has_acted = true
	if _check_end():
		return {"ok": true, "results": results}
	state_changed.emit()
	return {"ok": true, "results": results}


func _smash_obstacle(weapon: Dictionary, cell: Vector2i) -> Dictionary:
	## 直接点障碍物格：战车能轰碎，人物白打一发（打不碎）。
	var dist := Hex.distance(active_unit.cell, cell)
	if dist < int(weapon.range_min) or dist > int(weapon.range_max):
		return {"ok": false, "msg": "障碍物不在 %s 的射程内" % weapon.name}
	if Hex.first_blocker(active_unit.cell, cell, blocked).x >= 0:
		return {"ok": false, "msg": "中间还隔着别的障碍物，打不到那一格"}
	if int(weapon.ammo) > 0:
		weapon.ammo = int(weapon.ammo) - 1
	if not active_unit.is_vehicle:
		active_unit.has_acted = true
		_log("%s 的 %s 打在障碍物上，石头纹丝不动（人物无法破坏障碍物）。" % [
			active_unit.label, weapon.name])
		state_changed.emit()
		return {"ok": true, "results": []}
	blocked.erase(cell)
	obstacle_destroyed.emit(cell)
	active_unit.has_acted = true
	_log("%s 用 %s 轰碎了障碍物。" % [active_unit.label, weapon.name])
	var results: Array = [{"target": null, "hit": true, "crit": "none", "damage": 0,
		"blocked_cell": cell, "blocked_destroyed": true}]
	attack_resolved.emit(active_unit, weapon, results)
	state_changed.emit()
	return {"ok": true, "results": results}


func end_turn() -> void:
	## 结束「我的回合」：我方存活单位一起交棒，转到敌方整回合。
	if not active_is_player() or _finished:
		return
	_log("你结束了本回合。")
	_start_enemy_phase()


# -------------------- AI 接口 --------------------

func ai_move(unit, cell: Vector2i) -> void:
	if unit == null or not unit.is_alive() or cell == unit.cell:
		return
	var path: Array = Hex.path(unit.cell, cell, unit.mp, grid_cols, grid_rows, blocked,
		occupied_cells(unit))
	if path.is_empty():
		return
	unit.cell = cell
	unit.mp -= path.size()
	unit.has_moved = true


func ai_attack(unit, weapon: Dictionary, target) -> Array:
	if unit == null or not unit.is_alive() or target == null or not target.is_alive():
		return []
	if int(weapon.ammo) <= 0:
		return []
	if not unit.can_hit(unit.cell, target, weapon, balance.combat_v2):
		return []
	var results := _execute_attack(unit, weapon, target)
	unit.has_acted = true
	_check_end()
	return results


# -------------------- 结算 --------------------

func _execute_attack(attacker, weapon: Dictionary, target) -> Array:
	# 远程弹道先看中间有没有障碍物：被挡就打不到目标
	if target != null and not bool(weapon.melee):
		var blocker := Hex.first_blocker(attacker.cell, target.cell, blocked)
		if blocker.x >= 0:
			return _resolve_blocked_shot(attacker, weapon, target, blocker)

	var targets: Array = [target]
	if bool(weapon.aoe) and int(weapon.aoe_radius) > 0:
		for u in units:
			if not u.is_alive() or u == attacker:
				continue
			if u.is_player != attacker.is_player \
					and Hex.distance(target.cell, u.cell) <= int(weapon.aoe_radius):
				targets.append(u)

	var results: Array = attacker.fire(weapon, targets, balance, rng)
	_log_attack(attacker, weapon, results)
	attack_resolved.emit(attacker, weapon, results)
	return results


func _resolve_blocked_shot(attacker, weapon: Dictionary, target, blocker: Vector2i) -> Array:
	## 弹道被障碍物挡住：目标完全不受伤害；战车顺手把障碍物轰碎，人物打不碎。
	if int(weapon.ammo) > 0:
		weapon.ammo = int(weapon.ammo) - 1
	var smashed := bool(attacker.is_vehicle)
	if smashed:
		blocked.erase(blocker)
		obstacle_destroyed.emit(blocker)
		_log("%s 用 %s 轰碎了挡路的障碍物，%s 毫发无损。" % [
			attacker.label, weapon.name, target.label])
	else:
		_log("%s 的 %s 被障碍物挡住，%s 毫发无损（人物打不碎障碍物）。" % [
			attacker.label, weapon.name, target.label])
	var results: Array = [{"target": target, "hit": false, "crit": "none", "damage": 0,
		"armor_left": target.armor, "hp_left": target.hp,
		"blocked_cell": blocker, "blocked_destroyed": smashed}]
	attack_resolved.emit(attacker, weapon, results)
	return results


func _log_attack(attacker, weapon: Dictionary, results: Array) -> void:
	var totals: Dictionary = {}
	var landed := 0
	for r in results:
		if bool(r.hit):
			landed += 1
			totals[r.target.label] = int(totals.get(r.target.label, 0)) + int(r.damage)
	var parts: Array = []
	for label in totals.keys():
		parts.append("%s -%d" % [label, int(totals[label])])
	var crits := 0
	for r in results:
		if bool(r.hit) and str(r.crit) != "none":
			crits += 1
	_log("%s 使用 %s：%d/%d 命中%s%s" % [
		attacker.label, weapon.name, landed, results.size(),
		"，%d 次暴击" % crits if crits > 0 else "",
		(" → " + "，".join(parts)) if not parts.is_empty() else "",
	])


func _find_weapon(unit, weapon_id: String) -> Dictionary:
	if unit == null:
		return {}
	for w in unit.weapons:
		if str(w.id) == weapon_id:
			return w
	return {}


func _on_unit_died(u) -> void:
	_log("%s 被击毁" % u.label)
	unit_died.emit(u)
	# 被操作的单位阵亡后，自动切到下一个还能行动的我方单位
	if u.is_player and phase == "player" and u == active_unit:
		active_unit = _next_player_unit()
		state_changed.emit()


func _check_end() -> bool:
	if _finished:
		return true
	var enemies_dead := true
	for e in enemies:
		if e.is_alive():
			enemies_dead = false
			break
	var players_dead := true
	for p in player_units:
		if p.is_alive():
			players_dead = false
			break
	if enemies_dead:
		_on_victory()
		return true
	if players_dead:
		_on_defeat("全员失去战斗力")
		return true
	return false


func _on_victory() -> void:
	if _finished:
		return
	_finished = true
	phase = "done"
	var summary := {"gold": 0, "exp": 0, "drops": [], "bounties": []}
	for e in enemies:
		if e.is_alive():
			continue
		var eid: String = str(e.source_id)
		if eid.is_empty() or not _gd.enemies.has(eid):
			continue
		var row: Dictionary = _gd.enemies[eid]
		_gs.kill_counts[eid] = int(_gs.kill_counts.get(eid, 0)) + 1
		summary.gold += int(row.get("gold", 0))
		summary.exp += int(row.get("exp", 0))
		if bool(row.get("is_bounty", false)):
			summary.bounties.append(row.id)
			_gs.defeated_bounties[row.id] = true
		for drop in row.get("drops", []):
			if drop.get("item") == "e_scorpion":
				summary.drops.append({"item": "e_scorpion", "qty": 1})
				if not _gs.owns("e_scorpion"):
					_gs.owned_parts.append("e_scorpion")
			elif _rng_ok(drop):
				var qty := int(drop.get("qty", 1))
				summary.drops.append({"item": drop.item, "qty": qty})
				_gs.inventory[drop.item] = int(_gs.inventory.get(drop.item, 0)) + qty

	_gs.gold += summary.gold
	_sync_to_state()
	_log("=== 胜利！+%dG, +%dEXP ===" % [summary.gold, summary.exp])
	victory.emit(summary)


func _rng_ok(drop: Dictionary) -> bool:
	return rng.randf() <= float(drop.get("rate", 0))


func _on_defeat(reason: String = "") -> void:
	if _finished:
		return
	_finished = true
	phase = "done"
	# 先同步战损与剩余弹药，再走惩罚：refund_defeat 会把装甲/HP 修满。
	_sync_to_state()
	var lost: int = _gs.refund_defeat()
	_log("=== 失败！%s 被拖回城镇，损失 %dG + 修理费 ===" % [reason, lost])
	defeat.emit({"lost_gold": lost, "reason": reason})


func _sync_to_state() -> void:
	for u in player_units:
		if u.is_vehicle:
			var rt: Dictionary
			if int(u.runtime_index) < 0:
				rt = _gs.vehicle_runtime
				_gs.player_hp = int(u.hp)
			else:
				rt = _gs.extra_vehicles[int(u.runtime_index)].runtime
			rt.armor = int(u.armor)
			rt.hp = int(u.hp)
			for i in u.weapons.size():
				if i < rt.weapons.size():
					rt.weapons[i].ammo = int(u.weapons[i].ammo)
		elif u.is_character and int(u.char_index) >= 0:
			if int(u.char_index) < _gs.characters.size():
				_gs.characters[int(u.char_index)].hp = int(u.hp)


func _log(msg: String) -> void:
	logged.emit(msg)
