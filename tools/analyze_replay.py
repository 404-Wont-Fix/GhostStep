"""流式分析一个或多个 GhostStep JSONL；输出中文 Markdown、JSON 与 CSV，无第三方依赖。
用法: python3 tools/analyze_replay.py session*.jsonl --output analysis/report
文件分开分析，不把重复开局文件或缺帧窗口拼成完整对局。
"""
import argparse
import collections
import csv
import json
import math
from pathlib import Path


def iter_lines(path):
    with Path(path).open(encoding='utf-8-sig') as source:
        yield from source


def summary(hist):
    n = sum(hist.values())
    if not n:
        return dict(samples=0)
    def percentile(q):
        cumulative = 0
        for value, count in sorted(hist.items()):
            cumulative += count
            if cumulative >= math.ceil(n*q):
                return value
    return dict(samples=n, mean=sum(v*c for v,c in hist.items())/n,
                p50=percentile(.5), p95=percentile(.95), p99=percentile(.99),
                maximum=max(hist), over33ms=sum(c for v,c in hist.items() if v>33))


def analyze(path):
    events, reasons, counts = (collections.Counter() for _ in range(3))
    stages = collections.defaultdict(collections.Counter)
    amplitudes = collections.Counter()
    damages, contexts, io_events, episodes, segments, warnings = {}, {}, [], [], [], []
    previous = segment = header = None
    last_seq = None
    session_index = 0
    headers = []
    first_frame = last_frame = None
    def close_segment(incomplete):
        nonlocal segment
        if segment is not None:
            segment['rightCensored'] = incomplete
            segment['netDisplacement'] = math.hypot(segment['endX']-segment['startX'], segment['endY']-segment['startY'])
            segments.append(segment)
            segment = None
    for number, line in enumerate(iter_lines(path), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
            if not isinstance(row, dict):
                raise ValueError('record is not an object')
        except (ValueError, json.JSONDecodeError) as exc:
            counts['invalid_lines'] += 1
            if len(warnings)<20:
                warnings.append(f'第 {number} 行无法解析：{exc}')
            close_segment(True); previous = None
            continue
        ev = row.get('ev', 'snapshot'); events[ev] += 1
        seq = row.get('seq')
        if isinstance(seq, int):
            if last_seq is not None:
                if seq > last_seq+1:
                    counts['missing_sequences'] += seq-last_seq-1
                elif seq <= last_seq:
                    counts['sequence_resets_or_duplicates'] += 1
                    close_segment(True); previous = None
            last_seq = seq
        if ev == 'session_start':
            if header is not None:
                warnings.append('同一文件含多个会话起点；统计为文件汇总，伤害按会话隔离关联。')
            header = row
            session_index += 1
            headers.append(row)
            close_segment(True); previous=None
        elif ev == 'recording_io_paused':
            io_events.append(row)
        elif ev == 'avoidance_end':
            episodes.append(row)
        elif ev == 'damage_attempt':
            damages[(session_index,row.get('attemptId', f'line-{number}'))] = dict(row,sessionIndex=session_index)
        elif ev == 'damage_context':
            s = row.get('snapshot', {}); m = s.get('metrics', {})
            contexts[(session_index,row.get('attemptId'))] = dict(snapshotFrame=s.get('frame'), reason=s.get('reason'),
                wallDistance=s.get('wallDist'), playerX=s.get('px'), playerY=s.get('py'),
                commandX=s.get('cx'), commandY=s.get('cy'), rawX=s.get('ix'), rawY=s.get('iy'),
                metrics=m, model=s.get('model'), hazards=s.get('hazards'), plan=s.get('plan'),
                hazardOmitted=s.get('hazardOmitted'), phase=row.get('phase'))
        elif ev == 'hit':
            d = damages.setdefault((session_index,row.get('attemptId', f'line-{number}')), {'sessionIndex':session_index,'attemptId':row.get('attemptId')})
            d['observedHpLoss'] = row.get('dmg'); d['observedFrame'] = row.get('frame')
        if ev != 'snapshot' or not all(k in row for k in ('frame', 'px', 'py')):
            continue
        counts['snapshots'] += 1
        first_frame = row['frame'] if first_frame is None else first_frame
        last_frame = row['frame']
        contiguous = (previous is not None and row['frame']==previous['frame']+1
                      and row.get('room')==previous.get('room')
                      and (row.get('tick') is None or previous.get('tick') is None
                           or row['tick']==previous['tick']+1))
        if not contiguous:
            if previous is not None:
                counts['snapshot_discontinuities'] += 1
            close_segment(True)
        if contiguous and segment is not None and previous.get('active'):
            dx,dy=row['px']-previous['px'],row['py']-previous['py']
            distance=math.hypot(dx,dy)
            segment['pathDistance'] += distance; segment['observedSteps'] += 1
            segment['endX'],segment['endY'],segment['endFrame']=row['px'],row['py'],row['frame']
            f=row.get('feedback', {})
            if f.get('decisionId')==previous.get('decisionId') and f.get('dt')==1:
                segment['hookSteps'] += bool(f.get('hookSeen'))
            if distance<.15 and math.hypot(previous.get('cx',0),previous.get('cy',0))>.9:
                counts['low_progress_steps'] += 1
                if 0 <= row.get('wallDist',-1) <= 10:
                    counts['low_progress_near_wall_steps'] += 1
        if row.get('active'):
            counts['active_snapshots'] += 1
            amplitudes[round(math.hypot(row.get('cx',0),row.get('cy',0)),2)] += 1
            if segment is None:
                segment=dict(startFrame=row['frame'],endFrame=row['frame'],room=row.get('room'),
                    startX=row['px'],startY=row['py'],endX=row['px'],endY=row['py'],
                    startReason=row.get('reason'),leftCensored=not contiguous,
                    pathDistance=0.,observedSteps=0,hookSteps=0,commands=0,directionChanges=0,
                    firstAngleDegrees=math.degrees(math.atan2(row.get('cy',0),row.get('cx',0))))
            if contiguous and previous.get('active'):
                ax,ay=previous.get('cx',0),previous.get('cy',0);bx,by=row.get('cx',0),row.get('cy',0)
                if ax*ax+ay*ay>.01 and bx*bx+by*by>.01 and abs(math.atan2(ax*by-ay*bx,ax*bx+ay*by))>math.pi/4:
                    segment['directionChanges'] += 1
            segment['commands'] += 1
        else:
            close_segment(False)
        reasons[row.get('reason','unknown')] += 1
        m=row.get('metrics', {})
        if m.get('complete') is False:
            counts['incomplete_search_snapshots'] += 1
        if 'budget' in row.get('reason',''):
            counts['budget_failure_snapshots'] += 1
        for key,value in row.get('perfPrevious',{}).items():
            if key.endswith('Ms') and isinstance(value,(int,float)) and math.isfinite(value):
                stages[key][round(value,3)] += 1
        previous=row
    close_segment(True)
    for key,context in contexts.items():
        damages.setdefault(key, {})['context']=context
    for d in damages.values():
        d['contactPredictedAtDamage']=(d.get('predictedHit')==0)
        d['classification']='observed_hp_loss' if 'observedHpLoss' in d else 'attempt_only_or_death'
    return dict(file=str(Path(path).resolve()),header=header,headers=headers,counts=counts,events=events,reasons=reasons,
                firstSnapshotFrame=first_frame,lastSnapshotFrame=last_frame,amplitudes=amplitudes,
                stages={k:summary(v) for k,v in stages.items()},ioPauseEvents=io_events,
                damage=list(damages.values()),recordedEpisodes=episodes,observedSegments=segments,warnings=warnings,
                limitations=['实际位移含玩家惯性、外力、地形影响，不代表 mod 的因果贡献。',
                             '缺帧处分段；保留样本比例不是整局成功率。',
                             'plannedDisplacement 是预测窗口末端直线位移；pathDistance 是已观测轨迹长度。',
                             '死亡前 damage_attempt 可能没有后续 HP 轮询；不将两者重复累计。'])


def write_reports(reports, output):
    output=Path(output);output.mkdir(parents=True,exist_ok=True)
    (output/'report.json').write_text(json.dumps(reports,ensure_ascii=False,indent=2),encoding='utf-8')
    lines=['# GhostStep 回放诊断','', '方向角：0° 向右，90° 向下。距离单位：游戏坐标像素；步数按相邻快照统计，不强行换算秒。','']
    with (output/'segments.csv').open('w',encoding='utf-8-sig',newline='') as f:
        fields=['file','startFrame','endFrame','room','startReason','commands','observedSteps','pathDistance','netDisplacement','firstAngleDegrees','directionChanges','hookSteps','leftCensored','rightCensored']
        writer=csv.DictWriter(f,fieldnames=fields,extrasaction='ignore');writer.writeheader()
        for report in reports:
            for s in report['observedSegments']:
                writer.writerow(dict(s,file=report['file']))
    with (output/'episodes.csv').open('w',encoding='utf-8-sig',newline='') as f:
        fields=['file','episodeId','startFrame','frame','room','startReason','triggerId','triggerKind','endReason',
                'commands','observedSteps','hookSteps','pathDistance','netDisplacement','lastCommandX','lastCommandY','incomplete']
        writer=csv.DictWriter(f,fieldnames=fields,extrasaction='ignore');writer.writeheader()
        for report in reports:
            for e in report['recordedEpisodes']:
                writer.writerow(dict(e,file=report['file']))
    with (output/'damage.csv').open('w',encoding='utf-8-sig',newline='') as f:
        fields=['file','attemptId','frame','srcT','srcV','reason','predictedHit','observedHpLoss','episodeId','wallDistance','evaluated','selectedRisk']
        writer=csv.DictWriter(f,fieldnames=fields,extrasaction='ignore');writer.writeheader()
        for r in reports:
            for d in r['damage']:
                c=d.get('context',{});m=c.get('metrics',{})
                writer.writerow(dict(d,file=r['file'],wallDistance=c.get('wallDistance'),evaluated=m.get('evaluated'),selectedRisk=m.get('selectedRisk')))
    # 第二遍流式导出逐决策数据，不把所有帧驻留内存。
    with (output/'decisions.csv').open('w',encoding='utf-8-sig',newline='') as f:
        fields=['file','frame','decisionId','episodeId','reason','active','rawX','rawY','commandX','commandY','angleDegrees',
                'triggerId','triggerKind','nominalHit','selectedHit','plannedDisplacement','selectedEndX','selectedEndY',
                'distanceForDecision','observedDistance','observedDeltaX','observedDeltaY','hookSeen','velocityError']
        writer=csv.DictWriter(f,fieldnames=fields);writer.writeheader()
        for report in reports:
            for line in iter_lines(report['file']):
                try:
                    s=json.loads(line)
                except ValueError:
                    continue
                if not isinstance(s,dict) or s.get('ev','snapshot')!='snapshot' or 'px' not in s:
                    continue
                m=s.get('metrics',{});fb=s.get('feedback',{})
                valid=fb.get('dt')==1
                cx,cy=s.get('cx',0),s.get('cy',0)
                writer.writerow(dict(file=report['file'],frame=s.get('frame'),decisionId=s.get('decisionId'),
                    episodeId=s.get('episodeId'),reason=s.get('reason'),active=s.get('active'),
                    rawX=s.get('ix'),rawY=s.get('iy'),commandX=cx,commandY=cy,
                    angleDegrees=math.degrees(math.atan2(cy,cx)) if math.hypot(cx,cy)>.01 else None,
                    triggerId=m.get('triggerId'),triggerKind=m.get('triggerKind'),nominalHit=m.get('nominalHit'),selectedHit=m.get('selectedHit'),
                    plannedDisplacement=m.get('plannedDisplacement'),selectedEndX=m.get('selectedEndX'),selectedEndY=m.get('selectedEndY'),
                    distanceForDecision=fb.get('decisionId') if valid else None,
                    observedDistance=fb.get('progress') if valid else None,observedDeltaX=fb.get('deltaX') if valid else None,
                    observedDeltaY=fb.get('deltaY') if valid else None,hookSeen=fb.get('hookSeen') if valid else None,
                    velocityError=fb.get('velocityError') if valid else None))
    for r in reports:
        h=r['header'] or {};c=r['counts']
        lines += [f"## {Path(r['file']).name}",'',f"种子：{h.get('seed','未知')}；构建指纹：{h.get('build',{}).get('sourceHash','缺失')}。",
                  f"快照 {c.get('snapshots',0)} 条，范围 {r['firstSnapshotFrame']}–{r['lastSnapshotFrame']}；缺失序号 {c.get('missing_sequences',0)}。",
                  f"接管快照 {c.get('active_snapshots',0)} 条；低位移步骤 {c.get('low_progress_steps',0)}，其中近墙 {c.get('low_progress_near_wall_steps',0)}。",
                  f"预算失败快照 {c.get('budget_failure_snapshots',0)}；观测避让片段 {len(r['observedSegments'])}，已保存避让结束事件 {len(r['recordedEpisodes'])}。",'',
                  f"原因分布：`{json.dumps(r['reasons'],ensure_ascii=False)}`",'', '| 伤害回调 | 帧 | 来源 | 当时原因 | 预测首碰撞 | 墙距 | 已评估 |','|---|---:|---|---|---:|---:|---:|']
        for d in r['damage']:
            ctx=d.get('context',{})
            lines.append(f"| {d.get('attemptId','?')} | {d.get('frame','?')} | {d.get('srcT','?')}.{d.get('srcV','?')} | {d.get('reason','?')} | {d.get('predictedHit','?')} | {ctx.get('wallDistance','?')} | {ctx.get('metrics',{}).get('evaluated','?')} |")
        lines += ['',f"慢写暂停事件：{[e.get('writeMs') for e in r['ioPauseEvents']]} ms。事件可能位于被淘汰的快照区间，不能仅看保留快照最大值。",'', '| 阶段 | 样本数 | P95 ms | 最大 ms |','|---|---:|---:|---:|']
        for k,v in r['stages'].items():
            lines.append(f"| {k} | {v['samples']} | {v.get('p95')} | {v.get('maximum')} |")
        lines += ['',*r['warnings'],'',*r['limitations'],'']
    (output/'report.md').write_text('\n'.join(lines),encoding='utf-8')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('files',nargs='+',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    reports=[analyze(p) for p in args.files]
    write_reports(reports,args.output)
    print(args.output.resolve()/'report.md')
