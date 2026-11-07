"""Drive actual renderer keys and authorization flow without touching a system."""
import contextlib
import io
import json
import tempfile
import sys
import curses
import importlib.util
import os
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('cleanup_windows',Path(__file__).resolve().parents[1]/'sweenlab-cleanup.py')
c=importlib.util.module_from_spec(spec); spec.loader.exec_module(c)

class Screen:
    def __init__(self,keys): self.keys=iter(keys); self.drawn=[]
    def keypad(self,*args): pass
    def erase(self): pass
    def getmaxyx(self): return 24,80
    def derwin(self,*args): return self
    def box(self): pass
    def bkgd(self,*args): pass
    def addnstr(self,y,x,text,n,*args): self.drawn.append(text[:n])
    def move(self,*args): pass
    def refresh(self): pass
    def get_wch(self): return next(self.keys)

class FakeUI:
    def __init__(self,answers): self.answers=iter(answers); self.calls=[]
    def ask(self,*args):
        self.calls.append(args)
        answer=next(self.answers)
        if isinstance(answer,Exception): raise answer
        return answer
    def message(self,title,text): return self.ask('review',title,text)
    def working(self,title,callback): return callback()

ITEMS=[{'path':'/var/cache/apt/archives/a.deb','action':'apt','fingerprint':[1,2,300,4,'hash']},
       {'path':'/var/cache/apt/archives/b.deb','action':'apt','fingerprint':[1,3,400,4,'hash2']}]

class Windows(unittest.TestCase):
    def drive(self,kind,keys,seed='',options=(),title='Test'):
        screen=Screen(keys)
        with patch.object(curses,'curs_set'),patch.object(curses,'has_colors',return_value=False):
            result=c.run(screen,kind,title,'Question',seed,options)
        return result,'\n'.join(screen.drawn)
    def test_palette_matches_creator_exactly(self):
        with patch.dict(os.environ,{'NO_COLOR':''}),patch.object(curses,'curs_set'),patch.object(curses,'has_colors',return_value=True),patch.object(curses,'start_color'),patch.object(curses,'use_default_colors'),patch.object(curses,'COLORS',256,create=True),patch.object(curses,'init_pair') as pairs,patch.object(curses,'color_pair',return_value=0):
            c.run(Screen(['\n']),'review','Test','Question','',[])
        self.assertEqual([x.args for x in pairs.call_args_list],[(1,208,-1),(2,114,-1),(3,curses.COLOR_BLACK,114),(4,252,-1),(5,252,236)])
    def test_delete_defaults_to_back(self):
        result,drawn=self.drive('review',['\n'],title='SweenLab | Delete selected files')
        self.assertEqual(result,('back',''))
        self.assertIn('< Delete files >',drawn)
    def test_arrow_required_for_final_delete(self):
        result,_=self.drive('review',[curses.KEY_RIGHT,'\n'],title='SweenLab | Delete selected files')
        self.assertEqual(result,('next',''))
    def test_no_candidates_preselected(self):
        result,_=self.drive('check',['\n'],options=[('1','a.deb')])
        self.assertEqual(result,('next',''))
    def test_space_selects_exact_file(self):
        result,_=self.drive('check',[curses.KEY_DOWN,' ','\n'],options=[('1','a'),('2','b')])
        self.assertEqual(result,('next','2'))
    def test_escape_aborts(self):
        self.assertEqual(self.drive('input',['\x1b'])[0],('abort',''))
    def test_setup_default_inventory_and_back_preserves_targets(self):
        a=SimpleNamespace(apply=False,exclude_path=[],journal_days=30)
        ui=FakeUI([('next','scan'),('next','host'),('back',''),('next','host'),('next','/var/log/journal'),('next','90'),('next','')])
        self.assertEqual(c.setup_windows(ui,a,['host','ct:200'],{}),['host'])
        self.assertFalse(a.apply); self.assertEqual(a.journal_days,90)
        self.assertEqual(a.exclude_path,['/var/log/journal'])
        self.assertEqual(ui.calls[0][3],'scan')
        self.assertEqual(ui.calls[3][3],'host')
    def test_empty_selection_skips(self):
        ui=FakeUI([('next','')]); self.assertEqual(c.review_files(ui,'host',ITEMS),[])
        self.assertEqual(ui.calls[0][3],'')
    def test_exact_selection_requires_all_confirmations(self):
        ui=FakeUI([('next','2'),('next',''),('next','reviewed'),('next','delete ct:200'),('next','')])
        self.assertEqual(c.review_files(ui,'ct:200',ITEMS),[ITEMS[1]])
        self.assertIn(ITEMS[1]['path'],ui.calls[-1][2])
        self.assertNotIn(ITEMS[0]['path'],ui.calls[-1][2])
    def test_wrong_target_never_authorizes(self):
        ui=FakeUI([('next','1'),('next',''),('next','reviewed'),('next','delete host'),('next',''),('next','')])
        self.assertEqual(c.review_files(ui,'ct:200',ITEMS),[])
        self.assertNotIn('Delete selected files',[x[1] for x in ui.calls])
    def test_final_back_keeps_selection_without_authorizing(self):
        ui=FakeUI([('next','1'),('next',''),('next','reviewed'),('next','delete host'),('back',''),('back','')])
        self.assertEqual(c.review_files(ui,'host',ITEMS),[])
        self.assertEqual(ui.calls[-1][3],'1')
    def test_abort_propagates_before_authorization(self):
        ui=FakeUI([('next','1'),c.WizardAbort()])
        with self.assertRaises(c.WizardAbort): c.review_files(ui,'host',ITEMS)
    def run_main(self,answers):
        ui=FakeUI(answers); calls=[]
        def fake_worker(target,request):
            calls.append((target,json.loads(json.dumps(request))))
            return json.dumps({'candidates':ITEMS,'notes':[],'df':'test filesystem'}) if request['mode']=='scan' else json.dumps({'complete':True,'removed_count':len(request['items'])})
        with tempfile.TemporaryDirectory() as folder, patch.object(c.os,'geteuid',return_value=0),patch.object(c.sys.stdin,'isatty',return_value=True),patch.object(c.sys.stdout,'isatty',return_value=True),patch.object(c,'WindowUI',return_value=ui),patch.object(c,'worker',side_effect=fake_worker),patch.object(sys,'argv',['cleanup','--in-guest','--reports',folder]),contextlib.redirect_stdout(io.StringIO()) as capture:
            # redirect_stdout replaces the patched stdout, so give the capture a tty flag.
            capture.isatty=lambda:True
            rc=c.main()
            reports=[json.loads(line) for path in Path(folder).glob('*.jsonl') for line in path.read_text().splitlines()]
        return rc,calls,reports
    def setup_answers(self,mode):
        return [('next',mode),('next','host'),('next',''),('next','30'),('next',''),('next','')]
    def test_full_inventory_never_calls_apply(self):
        rc,calls,events=self.run_main(self.setup_answers('scan')+[('next','')])
        self.assertEqual(rc,0);self.assertEqual([x[1]['mode'] for x in calls],['scan'])
        self.assertNotIn('authorized',[x['event'] for x in events])
    def test_full_apply_sends_only_reviewed_allowlist(self):
        rc,calls,events=self.run_main(self.setup_answers('apply')+[('next','2'),('next',''),('next','reviewed'),('next','delete host'),('next',''),('next',''),('next','')])
        self.assertEqual(rc,0);self.assertEqual([x[1]['mode'] for x in calls],['scan','apply'])
        self.assertEqual(calls[1][1]['items'],[ITEMS[1]])
        self.assertEqual([x['allowlist'] for x in events if x['event']=='authorized'],[[ITEMS[1]]])
    def test_full_abort_before_delete_never_calls_apply(self):
        rc,calls,events=self.run_main(self.setup_answers('apply')+[('next','1'),('next',''),('next','reviewed'),('next','delete host'),c.WizardAbort()])
        self.assertEqual(rc,0);self.assertEqual(len(calls),1)
        self.assertNotIn('authorized',[x['event'] for x in events])
    def test_invalid_selection_fails_closed(self):
        with self.assertRaises(RuntimeError): c.review_files(FakeUI([('next','99')]),'host',ITEMS)

if __name__=='__main__': unittest.main()
