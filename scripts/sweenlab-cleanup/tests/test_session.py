import contextlib
import importlib.util
import io
import os
from pathlib import Path
import unittest
from unittest.mock import patch

SCRIPT=Path(__file__).resolve().parents[1]/'sweenlab-cleanup.py'
spec=importlib.util.spec_from_file_location('cleanup_session',SCRIPT)
c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)

class Screen:
    def erase(self):pass
    def getmaxyx(self):return 24,80
    def box(self):pass
    def addnstr(self,*args):pass
    def refresh(self):pass

class Session(unittest.TestCase):
    def test_one_curses_session_for_dialogs_and_three_targets(self):
        ui=c.WindowUI();screen=Screen();calls=[]
        def wrapper(callback,*args):calls.append(callback);return callback(screen,*args)
        def flow():
            ui.ask('review','Review','text')
            for target in ['host','ct:200','vm:100']:ui.working(target,lambda:None)
            ui.ask('review','Finished','text')
            return 7
        with patch.object(c.curses,'wrapper',side_effect=wrapper),patch.object(c.curses,'curs_set'),patch.object(c.curses,'has_colors',return_value=False),patch.object(c,'run',return_value=('next','')):
            self.assertEqual(ui.session(flow),7)
        self.assertEqual(len(calls),1);self.assertIsNone(ui.screen)
    def test_messages_deferred_until_terminal_restored(self):
        ui=c.WindowUI();output=io.StringIO()
        def wrapper(callback):
            result=callback(Screen())
            self.assertEqual(output.getvalue(),'')
            return result
        with contextlib.redirect_stdout(output),patch.object(c.curses,'wrapper',side_effect=wrapper):
            ui.session(lambda:print('ordinary terminal message'))
        self.assertEqual(output.getvalue(),'ordinary terminal message\n')
    def test_exception_resets_screen_and_preserves_message(self):
        ui=c.WindowUI();output=io.StringIO()
        def flow():print('diagnostic');raise RuntimeError('failure')
        with contextlib.redirect_stdout(output),patch.object(c.curses,'wrapper',side_effect=lambda callback:callback(Screen())):
            with self.assertRaises(RuntimeError):ui.session(flow)
        self.assertIsNone(ui.screen);self.assertIn('diagnostic',output.getvalue())
    @unittest.skipUnless(os.name=='posix','POSIX terminal required')
    def test_actual_terminal_enters_and_exits_alternate_screen_once(self):
        import pty,subprocess,sys,fcntl,termios,struct
        master,slave=pty.openpty()
        fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',24,80,0,0))
        code="import importlib.util,sys; s=importlib.util.spec_from_file_location('cleanup',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);u=m.WindowUI();u.session(lambda:(u.working('host',lambda:print('DEFERRED_MARKER')),u.working('ct:200',lambda:None),u.working('vm:100',lambda:None)))"
        env={**os.environ,'TERM':'xterm-256color'};env.pop('NO_COLOR',None)
        process=subprocess.Popen([sys.executable,'-c',code,str(SCRIPT)],stdin=slave,stdout=slave,stderr=slave,env=env)
        os.close(slave);data=b''
        try:
            while True:
                try:chunk=os.read(master,65536)
                except OSError:break
                if not chunk:break
                data+=chunk
        finally:os.close(master)
        self.assertEqual(process.wait(timeout=5),0,data.decode(errors='replace'))
        self.assertEqual(data.count(b'\x1b[?1049h'),1)
        self.assertEqual(data.count(b'\x1b[?1049l'),1)
        self.assertGreater(data.index(b'DEFERRED_MARKER'),data.index(b'\x1b[?1049l'))

if __name__=='__main__':unittest.main()
