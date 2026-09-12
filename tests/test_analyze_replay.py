import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

spec=importlib.util.spec_from_file_location('replay',Path(__file__).resolve().parents[1]/'tools/analyze_replay.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class ReplayTests(unittest.TestCase):
    def test_gap_does_not_become_travel_or_duplicate_damage(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'trace.jsonl'
            rows=[{'ev':'session_start','seq':1,'seed':'a'},
                  {'seq':2,'frame':1,'tick':1,'decisionId':1,'room':1,'px':0,'py':0,'active':True,'cx':1,'cy':0},
                  {'seq':3,'frame':2,'tick':2,'decisionId':2,'room':1,'px':3,'py':4,'active':False,
                   'feedback':{'dt':1,'decisionId':1,'hookSeen':True,'progress':5}},
                  {'seq':10,'frame':9,'tick':9,'decisionId':9,'room':1,'px':1000,'py':1000,'active':True,'cx':1,'cy':0},
                  {'seq':11,'ev':'damage_attempt','attemptId':1,'frame':9,'dmg':1},
                  {'seq':12,'ev':'hit','attemptId':1,'frame':10,'dmg':1},
                  {'seq':13,'ev':'recording_io_paused','writeMs':65}]
            p.write_text('\n'.join(json.dumps(r) for r in rows)+'\n{bad',encoding='utf-8')
            r=m.analyze(p)
            self.assertEqual(r['observedSegments'][0]['pathDistance'],5)
            self.assertEqual(r['observedSegments'][1]['pathDistance'],0)
            self.assertTrue(r['observedSegments'][1]['leftCensored'])
            self.assertEqual(len(r['damage']),1)
            self.assertEqual(r['damage'][0]['observedHpLoss'],1)
            self.assertEqual(r['counts']['missing_sequences'],6)
            self.assertEqual(r['counts']['invalid_lines'],1)
            m.write_reports([r],Path(tmp)/'out')
            for name in ['report.json','report.md','segments.csv','damage.csv','decisions.csv','episodes.csv']:
                self.assertTrue((Path(tmp)/'out'/name).exists())
            self.assertEqual(r['ioPauseEvents'][0]['writeMs'],65)

    def test_files_with_same_frame_numbers_remain_separate(self):
        with tempfile.TemporaryDirectory() as tmp:
            for name in ['a','b']:
                p=Path(tmp)/(name+'.jsonl')
                p.write_text(json.dumps({'ev':'session_start','seq':1,'seed':name})+'\n')
            reports=[m.analyze(p) for p in sorted(Path(tmp).glob('*.jsonl'))]
            self.assertEqual([r['header']['seed'] for r in reports],['a','b'])
            self.assertTrue(all(not r['observedSegments'] for r in reports))

    def test_dodge_dir8_histogram(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'trace.jsonl'
            # 3次向右(dx=1,dy=0), 1次向左上(dx=-0.7,dy=-0.7)
            rows=[
                {'ev':'session_start','seq':1,'seed':'d8'},
                {'seq':2,'frame':1,'tick':1,'decisionId':1,'room':1,'px':0,'py':0,'active':True,'cx':1,'cy':0,'dx':1,'dy':0},
                {'seq':3,'frame':2,'tick':2,'decisionId':2,'room':1,'px':1,'py':0,'active':True,'cx':1,'cy':0,'dx':1,'dy':0},
                {'seq':4,'frame':3,'tick':3,'decisionId':3,'room':1,'px':2,'py':0,'active':True,'cx':1,'cy':0,'dx':1,'dy':0},
                {'seq':5,'frame':4,'tick':4,'decisionId':4,'room':1,'px':3,'py':0,'active':True,'cx':-0.7,'cy':-0.7,'dx':-0.7,'dy':-0.7},
            ]
            p.write_text('\n'.join(json.dumps(r) for r in rows)+'\n',encoding='utf-8')
            r=m.analyze(p)
            d8=r['dodgeDir8']
            self.assertEqual(d8.get('右',0),3)
            self.assertEqual(d8.get('左上',0),1)
            self.assertEqual(sum(d8.values()),4)
            # 验证 decisions.csv 包含 dodgeDir8 列
            m.write_reports([r],Path(tmp)/'out')
            import csv
            with open(Path(tmp)/'out'/'decisions.csv',encoding='utf-8-sig') as f:
                reader=csv.DictReader(f)
                rows_csv=list(reader)
            self.assertIn('dodgeDir8',rows_csv[0])
            self.assertIn('dodgeDirX',rows_csv[0])
            active_rows=[r for r in rows_csv if r['active']=='True']
            self.assertEqual(active_rows[0]['dodgeDir8'],'右')
            self.assertEqual(active_rows[3]['dodgeDir8'],'左上')


class AnimCoverageTests(unittest.TestCase):
    """本轮新增：动画库缺口 + 跳跃实测事件必须能进报告（离线一键出清单）。"""

    def _report(self, tmp):
        p=Path(tmp)/'anim.jsonl'
        rows=[{'ev':'session_start','seq':1,'seed':'a'},
              {'ev':'anim_missing','seq':2,'frame':10,'entityType':29,'variant':1,'animation':'hop'},
              {'ev':'anim_missing','seq':3,'frame':40,'entityType':29,'variant':1,'animation':'hop'},
              {'ev':'anim_missing','seq':4,'frame':41,'entityType':864,'variant':0,'animation':'shoot2'},
              {'ev':'hop_measured','seq':5,'frame':50,'entityType':29,'variant':1,'leap':120.0,
               'flight':10.0,'period':40.0,'windup':3.0,'aimErr':12.0,'anim':'hop'},
              {'ev':'hop_measured','seq':6,'frame':130,'entityType':29,'variant':1,'leap':80.0,
               'flight':12.0,'period':41.0,'windup':5.0,'aimErr':18.0,'anim':'hop'}]
        p.write_text('\n'.join(json.dumps(r) for r in rows)+'\n',encoding='utf-8')
        return m.analyze(p)

    def test_missing_animations_and_hop_measurements_are_collected(self):
        with tempfile.TemporaryDirectory() as tmp:
            r=self._report(tmp)
            self.assertEqual(len(r['animMissing']),3)
            self.assertEqual(r['animMissing'][0]['animation'],'hop')
            self.assertEqual(len(r['hopMeasured']),2)
            self.assertEqual(r['hopMeasured'][0]['windup'],3.0)
            self.assertEqual(r['hopMeasured'][1]['period'],41.0)
            # 事件计数要出现在 events 直方图里（报告里能一眼看到有没有数据）
            self.assertEqual(r['events']['anim_missing'],3)
            self.assertEqual(r['events']['hop_measured'],2)

    def test_report_and_csv_expose_the_gap_list(self):
        import csv as _csv
        with tempfile.TemporaryDirectory() as tmp:
            r=self._report(tmp)
            out=Path(tmp)/'out'
            m.write_reports([r],out)
            md=(out/'report.md').read_text(encoding='utf-8')
            self.assertIn('动画/跳跃预判实测',md)
            self.assertIn('动画库缺条目',md)
            self.assertIn('跳跃型敌人实测',md)
            gaps=list(_csv.DictReader((out/'anim_gaps.csv').open(encoding='utf-8-sig')))
            hops=list(_csv.DictReader((out/'hop_measured.csv').open(encoding='utf-8-sig')))
            self.assertEqual(len(gaps),3)
            self.assertEqual(len(hops),2)
            self.assertEqual(hops[0]['entityType'],'29')
