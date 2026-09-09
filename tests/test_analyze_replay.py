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
