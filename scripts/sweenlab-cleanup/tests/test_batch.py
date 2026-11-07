import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('cleanup_batch',Path(__file__).resolve().parents[1]/'sweenlab-cleanup.py')
c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
ITEM={'path':'/var/cache/apt/archives/a.deb','action':'apt','fingerprint':[1,2,300,4,'hash']}

class UI:
    def __init__(self,answers): self.answers=iter(answers);self.prompts=[];self.progress=[]
    def ask(self,*args):
        self.prompts.append(args)
        result=next(self.answers)
        if isinstance(result,Exception):raise result
        return result
    def message(self,title,text):return self.ask('review',title,text)
    def working(self,title,callback): self.progress.append(title);return callback()

class Batch(unittest.TestCase):
    def execute(self,apply=False,answers=(),fail_scan=(),fail_apply=()):
        ui=UI(answers);events=[];calls=[]
        def log(event,**values):events.append(dict(event=event,**values))
        def worker(target,request):
            calls.append((target,json.loads(json.dumps(request))))
            if request['mode']=='scan':
                if target in fail_scan:raise RuntimeError('unsupported guest')
                return json.dumps({'candidates':[ITEM],'notes':[],'df':'test'})
            self.assertEqual(len([e for e in events if e['event']=='authorized']),len([e for e in events if e['event']=='authorized-batch'][0]['plans']))
            if target in fail_apply:raise RuntimeError('changed file')
            return json.dumps({'complete':True,'removed_count':len(request['items'])})
        args=SimpleNamespace(apply=apply,journal_days=30,exclude_path=[])
        with patch.object(c,'command',return_value='metadata'),patch.object(c,'worker',side_effect=worker):
            rc=c.run_batch(ui,args,['host','ct:200','vm:100'],Path('/audit.jsonl'),log)
        return rc,ui,events,calls
    def confirmations(self,selection='1\n2\n3'):
        return [('next',''),('next',selection),('next',''),('next','reviewed'),('next','delete batch'),('next',''),('next','')]
    def test_all_scans_before_one_combined_summary(self):
        rc,ui,events,calls=self.execute(answers=[('next',''),('next','')])
        self.assertEqual(rc,0);self.assertEqual([t for t,r in calls],['host','ct:200','vm:100'])
        self.assertEqual(len(ui.prompts),2)
        self.assertEqual([e for e in events if e['event']=='authorized'],[])
    def test_failed_scan_does_not_stop_remaining_guests_or_prompt(self):
        rc,ui,events,calls=self.execute(answers=[('next',''),('next','')],fail_scan=['ct:200'])
        self.assertEqual(rc,1);self.assertEqual(len(calls),3);self.assertEqual(len(ui.prompts),2)
        self.assertIn('ct:200: SKIPPED/FAILED',ui.prompts[0][2])
    def test_one_confirmation_cleans_all_reviewed_targets(self):
        rc,ui,events,calls=self.execute(apply=True,answers=self.confirmations())
        self.assertEqual(rc,0);self.assertEqual([r['mode'] for t,r in calls],['scan']*3+['apply']*3)
        for target,request in calls[3:]: self.assertEqual(request['items'],[ITEM])
        self.assertEqual(len([p for p in ui.prompts if p[1]=='Confirm target (required)']),1)
        review=next(p[2] for p in ui.prompts if p[1]=='Delete selected files')
        for target in ['host','ct:200','vm:100']:self.assertIn(target+' | ',review)
    def test_same_path_on_other_guests_not_authorized_by_one_selection(self):
        rc,ui,events,calls=self.execute(apply=True,answers=self.confirmations('2'))
        self.assertEqual([(t,r['items']) for t,r in calls if r['mode']=='apply'],[('ct:200',[ITEM])])
    def test_empty_selection_skips_every_apply(self):
        rc,ui,events,calls=self.execute(apply=True,answers=[('next',''),('next',''),('next','')])
        self.assertEqual(len(calls),3);self.assertFalse(any(e['event']=='authorized' for e in events))
    def test_abort_before_final_delete_keeps_all_targets_untouched(self):
        answers=self.confirmations();answers[-2]=c.WizardAbort()
        rc,ui,events,calls=self.execute(apply=True,answers=answers)
        self.assertEqual(len(calls),3);self.assertFalse(any(e['event']=='authorized' for e in events))
    def test_apply_error_continues_other_authorized_targets(self):
        rc,ui,events,calls=self.execute(apply=True,answers=self.confirmations(),fail_apply=['ct:200'])
        self.assertEqual(rc,1);self.assertEqual([t for t,r in calls if r['mode']=='apply'],['host','ct:200','vm:100'])
        self.assertEqual(len(ui.prompts),7)

if __name__=='__main__':unittest.main()
