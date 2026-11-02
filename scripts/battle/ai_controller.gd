extends RefCounted
## 敌方 / 自动托管 AI：先找「移动后能打到谁」的最佳格子与武器，再执行移动+攻击。
## 找不到可攻击位置时向最近的敌人靠近；static 单位永不移动。
## 没有 class_name，Controller 用 preload 调用。

const BM := preload("res://scripts/battle/battle_math.gd")
const Hex := preload("res://scripts/battle/hex_rules.gd")


static func take_turn(ctrl, unit) -> void:
	var foes: Array = ctrl.foes_of(unit)
	if foes.is_empty():
		return

	var cfg: Dictionary = ctrl.balance.combat_v2
	var reach: Dictionary = ctrl.reachable_for(unit)
	var candidates: Array = [unit.cell]
	if unit.ai != "static":
		for cell in reach.keys():
			candidates.append(cell)

	var best := {"score": -1.0, "cell": unit.cell, "weapon": null, "target": null}
	for cell in candidates:
		for weapon in unit.usable_weapons():
			for foe in foes:
				if not foe.is_alive():
					continue
				var dist := Hex.distance(cell, foe.cell)
				# 弹道被障碍物挡住时打不到，不要浪费弹药
				if not bool(weapon.melee) \
						and Hex.first_blocker(cell, foe.cell, ctrl.blocked).x >= 0:
					continue
				# 射程内照常打；超出最大射程也能强攻（最远 range_max×2），只是期望值会被命中衰减拉低
				if not unit.can_hit(cell, foe, weapon, cfg):
					continue
				var score := BM.expected_v2(unit.stats(), weapon, foe.stats(), dist, cfg)
				if unit.ai == "aggressive" and bool(foe.is_vehicle):
					score *= 1.35
				score += ctrl.rng.randf() * 0.4
				if score > float(best.score):
					best = {"score": score, "cell": cell, "weapon": weapon, "target": foe}

	if best.weapon != null:
		if best.cell != unit.cell:
			ctrl.ai_move(unit, best.cell)
		ctrl.ai_attack(unit, best.weapon, best.target)
		return

	if unit.ai == "static":
		return

	# 打不到就靠近最近的敌人；同距离时优先少走路。
	var foe_cells: Array = []
	for foe in foes:
		foe_cells.append(foe.cell)
	var move_best := {"cell": unit.cell, "dist": Hex.nearest_distance(unit.cell, foe_cells), "cost": 0}
	for cell in reach.keys():
		var d := Hex.nearest_distance(cell, foe_cells)
		var cost := int(reach[cell])
		if d < int(move_best.dist) or (d == int(move_best.dist) and cost < int(move_best.cost)):
			move_best = {"cell": cell, "dist": d, "cost": cost}
	if move_best.cell != unit.cell:
		ctrl.ai_move(unit, move_best.cell)
