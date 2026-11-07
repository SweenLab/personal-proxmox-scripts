import contextlib
import io
import importlib.util
from pathlib import Path
import stat
import types
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('cleanup',Path(__file__).resolve().parents[1]/'sweenlab-cleanup.py')
c=importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
# Load only definitions, never worker execution or controller main.
ns={'__name__':'testworker'}
exec(c.WORKER.split('req=json.loads')[0]+c.WORKER.split("req=json.loads(base64.b64decode(sys.argv[1]))",1)[1].split('\ntry:\n    if os.geteuid()',1)[0],ns)
ns['req']={'exclude_paths':[]}

class Safety(unittest.TestCase):
    def directory(self,mode=stat.S_IFDIR|0o755):
        return types.SimpleNamespace(st_mode=mode,st_uid=0)
    def check(self,mounts,excluded=None,mode=None):
        ns['req']={'exclude_paths':excluded or []}
        with patch.dict(ns,{'mounts':lambda:mounts}), patch.object(ns['os'],'lstat',return_value=self.directory(mode or stat.S_IFDIR|0o755)):
            ns['safe_dir']('/var/cache/apt/archives')
    def test_root_filesystem_allowed(self): self.check(['/'])
    def test_bind_mount_rejected(self):
        with self.assertRaises(RuntimeError): self.check(['/','/var/cache/apt/archives'])
    def test_nested_mount_rejected(self):
        with self.assertRaises(RuntimeError): self.check(['/','/var/cache/apt/archives/one.deb'])
    def test_parent_mount_rejected(self):
        with self.assertRaises(RuntimeError): self.check(['/','/var'])
    def test_nested_exclusion_rejects_action(self):
        with self.assertRaises(RuntimeError): self.check(['/'],['/var/cache/apt/archives/keep.deb'])
    def test_symlink_rejected(self):
        with self.assertRaises(RuntimeError): self.check(['/'],mode=stat.S_IFLNK|0o777)
    def test_world_writable_rejected(self):
        with self.assertRaises(RuntimeError): self.check(['/'],mode=stat.S_IFDIR|0o777)
    def test_hardlink_rejected(self):
        fake=types.SimpleNamespace(st_mode=stat.S_IFREG|0o644,st_uid=0,st_nlink=2)
        with patch.object(ns['os'],'fstat',return_value=fake):
            with self.assertRaises(RuntimeError): ns['fingerprint'](99)
    def worker_tail(self,mode,items,current):
        ns['req']={'mode':mode,'items':items,'exclude_paths':[]}
        tail=c.WORKER.split('\ntry:\n    if os.geteuid()',1)[1]
        code='try:\n    if os.geteuid()'+tail
        with patch.dict(ns,{'candidates':lambda:(current,[]),'run':lambda args:'inventory'}), patch.object(ns['os'],'geteuid',return_value=0), patch.object(ns['os'].path,'isfile',return_value=True), patch.object(ns['os'].path,'exists',return_value=False), patch.object(ns['os'],'unlink') as unlink, contextlib.redirect_stdout(io.StringIO()):
            try: exec(code,ns)
            except SystemExit: pass
            return unlink.call_count
    def test_inventory_cannot_unlink(self):
        self.assertEqual(self.worker_tail('scan',[],[{'path':'/fake'}]),0)
    def test_changed_manifest_fails_before_any_deletion(self):
        old={'path':'/fake','fingerprint':[1,2,3]}
        new={'path':'/fake','fingerprint':[1,2,4]}
        self.assertEqual(self.worker_tail('apply',[old],[new]),0)
    def test_missing_candidate_fails_before_any_deletion(self):
        self.assertEqual(self.worker_tail('apply',[{'path':'/fake'}],[]),0)
    def test_vm_truncated_output_rejected(self):
        with patch.object(c,'command',side_effect=['status: running','','{"exited":true,"exitcode":0,"out-truncated":true}']):
            with self.assertRaises(RuntimeError): c.worker('vm:100',{})
    def test_locked_guest_never_executes(self):
        with patch.object(c,'command',side_effect=['status: running','lock: backup']) as run:
            with self.assertRaises(RuntimeError): c.worker('ct:200',{})
            self.assertEqual(run.call_count,2)
    def test_stopped_container_never_executes(self):
        with patch.object(c,'command',return_value='status: stopped') as run:
            with self.assertRaises(RuntimeError): c.worker('ct:200',{})
            self.assertEqual(run.call_count,1)

if __name__=='__main__': unittest.main()
