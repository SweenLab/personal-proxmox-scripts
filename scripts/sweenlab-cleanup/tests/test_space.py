import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('cleanup_space',Path(__file__).resolve().parents[1]/'sweenlab-cleanup.py')
c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)

def record(count=2,size=1024,before=1000,after=2024,complete=True):
    return dict(complete=complete,removed_count=count,deleted_bytes=size,free_before_bytes=before,free_after_bytes=after)

class Space(unittest.TestCase):
    def test_positive_change_and_deleted_bytes_are_separate(self):
        text=c.space_report([('host',record(size=4096))],1)
        self.assertIn('4.00 KiB',text);self.assertIn('+1.00 KiB',text)
        self.assertLess(text.index('TOTAL FILES'),text.index('PER-SYSTEM'))
    def test_negative_change_is_not_clamped_to_zero(self):
        text=c.space_report([('host',record(after=488))],1)
        self.assertIn('-512.00 B',text)
    def test_totals_sum_measured_systems(self):
        text=c.space_report([('host',record()),('ct:200',record())],2)
        self.assertIn('4 confirmed files',text);self.assertIn('+2.00 KiB across 2/2',text)
    def test_missing_measurement_is_unavailable_not_freed_zero(self):
        text=c.space_report([('host',record(before=None,after=None))],2)
        self.assertIn('Unavailable (no measured cleanup results)',text)
        self.assertIn('incomplete coverage',text)
    def test_partial_result_labelled(self):
        text=c.space_report([('host',record(complete=False))],1)
        self.assertIn('(partial)',text)
    def test_multiple_receipts_then_one_summary(self):
        value=c.parse_cleanup_summary(json.dumps({'removed':'/file'})+'\n'+json.dumps(record()))
        self.assertEqual(value,record())
    def test_missing_or_duplicate_summary_fails(self):
        for text in ['{}',json.dumps(record())+'\n'+json.dumps(record())]:
            with self.assertRaises(RuntimeError): c.parse_cleanup_summary(text)
    def test_invalid_measurements_fail(self):
        for field in ['removed_count','deleted_bytes','free_before_bytes','free_after_bytes']:
            value=record();value[field]=-1
            with self.assertRaises(RuntimeError):c.parse_cleanup_summary(json.dumps(value))
    def test_error_retains_partial_output(self):
        with patch.object(c.subprocess,'run',return_value=type('Result',(),{'returncode':1,'stdout':json.dumps(record(complete=False)),'stderr':'failed'})()):
            with self.assertRaises(c.ExecutionError) as error:c.command(['worker'])
            self.assertEqual(c.parse_cleanup_summary(error.exception.output)['removed_count'],2)
    def test_worker_summary_reports_actual_counters(self):
        ns={}
        prefix=c.WORKER.split('req=json.loads')[0]
        definitions=c.WORKER.split('req=json.loads(base64.b64decode(sys.argv[1]))',1)[1].split('\ntry:\n    if os.geteuid()',1)[0]
        exec(prefix+definitions,ns)
        ns.update(removed=['/one'],deleted_bytes=700,free_before=1000)
        with patch.dict(ns,{'free_bytes':lambda:1800}):value=ns['cleanup_summary'](False)
        self.assertEqual(value,record(count=1,size=700,before=1000,after=1800,complete=False))

if __name__=='__main__':unittest.main()
