# 回放诊断工具

需要 Python 3.9+，无需额外依赖。在仓库目录执行：

```sh
python3 tools/analyze_replay.py /路径/session_1.jsonl /路径/session_2.jsonl --output analysis/report
```

输出到指定目录（同名结果会覆盖）：

- `report.md`：中文概览、原因分布、每次受伤对应原因/墙距/候选数、各阶段耗时。
- `report.json`：完整结构化统计，含伤害上下文的候选、危险列表、模型，以及运行时累计的避让事件。
- `decisions.csv`：每个快照的原始输入、输出向量与角度、触发威胁、预计碰撞时间、计划终点/位移、观测反馈。
- `segments.csv`：从连续快照重建的避让片段、实际路径长度、净位移、方向变化数、缺帧标记。
- `episodes.csv`：模组累计并保存的完整或截断避让摘要。旧版本没有此事件时为空。
- `damage.csv`：伤害回调与 HP 下降合并后的表，不将二者重复计数。

## 参数含义

- `reason`：nominal_safe=原操作预测安全；safe_evasion=找到无预测碰撞动作；reduce_exposure=仍有碰撞风险，仅降低评分；budget_no_improving_action=预算内未找到改进；no_improving_action=完成当前候选搜索仍无改进。
- `triggerId/triggerKind/triggerX/triggerY`：原输入最早预测相交的威胁；嵌入地形时 kind=terrain。它不是证明本次伤害来源的字段。
- `selectedSafe/riskImprovement`：选中候选在本模型中的结果，不是实机无伤保证或概率。
- `cx/cy`：实际提交的移动命令；角度 0° 向右、90° 向下。零向量没有方向。
- `selectedDuration`：候选假设维持输入的预测步数，不是已经执行的时长。控制器只执行第一步，下一次重新决策。
- `plannedDisplacement`：预测窗口末端相对当前玩家位置的直线距离，包含后续恢复原输入的部分；不是本次避让累计路程。
- `feedback.decisionId` / CSV `distanceForDecision`：实际反馈对应的**上一条命令**。不能把反馈中的位移归给当前帧新命令。
- `deltaX/deltaY/progress`：相邻观测的位移/长度；dt!=1 时 CSV 留空，不跨缺帧估计轨迹。
- `avoidance_end.pathDistance`：实际观测的相邻位移长度之和；`netDisplacement`：起止位置直线距离。包含惯性、外力、玩家输入等，不意味着位移全由 mod 造成。
- `incomplete/leftCensored/rightCensored`：房间变化、缺帧、死亡、退出等导致观测不完整，禁止把瞬移跨度累计为走位。
- `hookSteps`：有反馈证明移动输入回调被调用的观测步数，不等于伤害回避成功次数。

## 覆盖与性能

脚本流式读取快照，保留按片段和事件汇总的数据；逐帧 CSV 通过第二遍读取输出。多个文件各自分析，种子和帧号不混合；同一文件中的伤害编号按会话隔离。损坏行警告并截断当前连续片段，仍尝试读取后续有效行。

停止写盘后，普通快照会滚动淘汰，关键事件也有内存/单行上限。缺失序号并不等于漏掉相同数量的游戏更新。慢写暂停事件必须独立检查：慢写现场快照被淘汰后，保留样本的最大 writerMs 可能显示为 0。

低位移步骤（全力度输出后观测位移 <0.15）只作为筛查信号；启动加速、碰撞、状态限制都可能造成它，不能直接判定卡墙。片段内方向变化统计超过 45° 的连续命令变化，不能单凭数量认定抖动。脚本不声称计算了整局避伤成功率。
