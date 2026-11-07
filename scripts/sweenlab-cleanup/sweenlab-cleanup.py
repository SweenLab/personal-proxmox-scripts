#!/usr/bin/env python3
"""sweenlab | conservative Proxmox inventory and reviewed cache cleanup."""
import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

# Executed unchanged on the host, or through pct/qm inside a running guest.
SCRIPT_VERSION = "0.1.0"

WORKER = r'''
import base64, fcntl, hashlib, json, os, re, stat, subprocess, sys, time
req=json.loads(base64.b64decode(sys.argv[1]))
def run(args):
    p=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=30,env={"PATH":"/usr/sbin:/usr/bin:/sbin:/bin","LC_ALL":"C"})
    if p.returncode: raise RuntimeError(p.stderr[-2000:])
    return p.stdout

def mounts():
    return [re.sub(r"\\([0-7]{3})",lambda m:chr(int(m[1],8)),l.split()[4]) for l in open('/proc/self/mountinfo')]
def overlap(a,b): return a==b or a.startswith(b.rstrip('/')+'/') or b.startswith(a.rstrip('/')+'/')
def safe_dir(path):
    # Refuse symlink components, writable directories, and any non-root mount
    # overlapping the action directory (including bind mounts on the same device).
    cur=''
    for part in path.split('/')[1:]:
        cur+='/'+part
        s=os.lstat(cur)
        if not stat.S_ISDIR(s.st_mode) or s.st_uid!=0 or s.st_mode & 0o022: raise RuntimeError('unsafe directory '+cur)
    if any(m!='/' and overlap(path,m) for m in mounts()): raise RuntimeError('mounted path excluded: '+path)
    if any(overlap(path,x) for x in req['exclude_paths']): raise RuntimeError('path exclusion: '+path)
def fingerprint(fd):
    s=os.fstat(fd)
    if not stat.S_ISREG(s.st_mode) or s.st_uid!=0 or s.st_nlink!=1 or s.st_mode & 0o022: raise RuntimeError('unsafe file')
    h=hashlib.sha256()
    while True:
        b=os.read(fd,1024*1024)
        if not b: break
        h.update(b)
    return [s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,h.hexdigest()]
def candidates():
    result=[]; notes=[]
    dirs=[('/var/cache/apt/archives','apt',r'.+\.deb',7)]
    try:
        machine=open('/etc/machine-id').read().strip()
        if re.fullmatch('[0-9a-f]{32}',machine): dirs.append(('/var/log/journal/'+machine,'journal',r'system@[0-9a-f]+-[0-9a-f]+-[0-9a-f]+\.journal',req['days']))
    except OSError: pass
    for directory,action,pattern,days in dirs:
        try:
            safe_dir(directory)
            with os.scandir(directory) as entries:
                for e in entries:
                    if not re.fullmatch(pattern,e.name): continue
                    try:
                        with_fd=os.open(e.path,os.O_RDONLY|os.O_NOFOLLOW)
                        try: fp=fingerprint(with_fd)
                        finally: os.close(with_fd)
                        if fp[3] > (time.time()-days*86400)*1e9: continue
                        if action=='apt': run(['dpkg-deb','--info',e.path])
                        else: run(['journalctl','--file='+e.path,'--verify','--no-pager'])
                        result.append({'path':e.path,'action':action,'fingerprint':fp})
                        if len(result)>300: raise RuntimeError('over 300 candidates; narrow scope manually')
                    except (OSError,subprocess.SubprocessError,RuntimeError) as ex:
                        if str(ex).startswith('over 300'): raise
                        notes.append(e.path+': '+str(ex))
        except (OSError,RuntimeError) as ex: notes.append(directory+': '+str(ex))
    if len(result)>300: raise RuntimeError("over 300 candidates; inspect in-guest or narrow scope")
    return result,notes
try:
    if os.geteuid()!=0: raise RuntimeError('root required')
    if not os.path.isfile('/etc/debian_version'): raise RuntimeError('only Debian-family systems supported')
    # Use the same POSIX record lock as APT. Never remove lock files.
    locks=[]
    for p in ['/var/lib/dpkg/lock-frontend','/var/lib/dpkg/lock','/var/cache/apt/archives/lock']:
        if os.path.exists(p):
            fd=os.open(p,os.O_RDWR|os.O_NOFOLLOW); locks.append(fd)
            fcntl.lockf(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    items,notes=candidates()
    if req['mode']=='scan':
        print(json.dumps({'candidates':items,'notes':notes,'df':run(['df','-hT','/']),'mounts':run(['findmnt','-rn','-o','TARGET,SOURCE,FSTYPE'])}))
    else:
        current={x['path']:x for x in items}
        removed=[]
        for old in req['items']:
            if current.get(old['path'])!=old: raise RuntimeError('candidate changed or no longer eligible: '+old['path'])
        for old in req['items']:
            path=old['path']; directory=os.path.dirname(path); name=os.path.basename(path)
            safe_dir(directory)
            dfd=os.open(directory,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
            try:
                fd=os.open(name,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=dfd)
                try:
                    if fingerprint(fd)!=old['fingerprint']: raise RuntimeError('file changed: '+path)
                    s=os.stat(name,dir_fd=dfd,follow_symlinks=False)
                    if (s.st_dev,s.st_ino)!=(old['fingerprint'][0],old['fingerprint'][1]): raise RuntimeError('file replaced')
                    os.unlink(name,dir_fd=dfd); removed.append(path)
                    print(json.dumps({'removed':path}),flush=True)
                finally: os.close(fd)
            finally: os.close(dfd)
        print(json.dumps({'complete':True,'removed_count':len(removed),'df':run(['df','-hT','/'])}))
except Exception as ex:
    print(json.dumps({'error':str(ex)}),flush=True); sys.exit(1)
'''


def command(args, timeout=90):
    p = subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                       env={**os.environ, 'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LC_ALL': 'C'})
    if p.returncode:
        raise RuntimeError(f'{args[:3]}: {p.stderr} {p.stdout}')
    return p.stdout


def worker(target, request):
    data = base64.b64encode(json.dumps(request).encode()).decode()
    args = ['python3', '-c', WORKER, data]
    if target.startswith('ct:'):
        ident = target.split(':')[1]
        if command(['pct', 'status', ident]).strip() != 'status: running':
            raise RuntimeError('container is not running')
        if re.search(r'^lock:', command(['pct', 'config', ident]), re.M):
            raise RuntimeError('container has a Proxmox task lock')
        args = ['pct', 'exec', ident, '--'] + args
    elif target.startswith('vm:'):
        ident = target.split(':')[1]
        if command(['qm', 'status', ident]).strip() != 'status: running':
            raise RuntimeError('VM is not running')
        if re.search(r'^lock:', command(['qm', 'config', ident]), re.M):
            raise RuntimeError('VM has a Proxmox task lock')
        # A timeout can leave a guest process running. Do not retry automatically.
        raw = command(['qm', 'guest', 'exec', ident, '--synchronous', '1', '--timeout', '120', '--'] + args, 150)
        response = json.loads(raw)
        if not response.get('exited') or response.get('exitcode') != 0 or response.get('out-truncated') or response.get('err-truncated'):
            raise RuntimeError('guest execution incomplete/failed/truncated; inspect manually: '+raw)
        return response.get('out-data', '')
    return command(args, 150)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--version', action='version', version='sweenlab cleanup '+SCRIPT_VERSION)
    ap.add_argument('--apply', action='store_true', help='interactive reviewed cleanup; default is inventory')
    ap.add_argument('--in-guest', action='store_true', help='inspect this Debian guest only; no Proxmox tools')
    ap.add_argument('--targets', default='all', help='all or comma-separated host,ct:200,vm:100')
    ap.add_argument('--exclude-target', action='append', default=[])
    ap.add_argument('--exclude-path', action='append', default=[], help='absolute path; applies inside every target')
    ap.add_argument('--journal-days', type=int, default=30, help='minimum archived system journal file age, >=30')
    ap.add_argument('--reports', default='/var/log/sweenlab/cleanup')
    a = ap.parse_args()
    if os.geteuid() != 0: ap.error('run as root')
    if a.journal_days < 30: ap.error('journal retention must be at least 30 days')
    for p in a.exclude_path:
        if not p.startswith('/') or '..' in p.split('/'): ap.error('exclusions must be absolute without ..')
    if a.apply and not sys.stdin.isatty(): ap.error('--apply requires an interactive terminal')
    os.umask(0o077)
    reportdir = Path(a.reports)
    reportdir.mkdir(parents=True, exist_ok=True)
    # Local audit and controller lock only: inventory never changes cleanup targets.
    import fcntl
    lock = open(reportdir / '.lock', 'a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    report = reportdir / (stamp+'-'+str(os.getpid())+'.jsonl')
    audit = open(report, 'x', buffering=1)
    def log(event, **values):
        audit.write(json.dumps({'time':dt.datetime.now(dt.timezone.utc).isoformat(), 'event':event, **values})+'\n')
        audit.flush(); os.fsync(audit.fileno())
    log('start', options=vars(a), script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    accent='\033[38;5;208m' if sys.stdout.isatty() else ''
    reset='\033[0m' if accent else ''
    print('\n'+accent+'sweenlab | cleanup review'+reset+'\n'+('reviewed cleanup' if a.apply else 'inventory only')+' | report: '+str(report))
    targets=['host']
    if not a.in_guest:
        for kind, tool in [('ct','pct'),('vm','qm')]:
            try:
                listing=command([tool,'list']); log('guest-list',kind=kind,output=listing)
                targets += [kind+':'+line.split()[0] for line in listing.splitlines()[1:] if line.split() and line.split()[0].isdigit()]
            except Exception as ex: log('discovery-error',kind=kind,error=str(ex)); print(str(ex))
        for cmd in [['pveversion','-v'],['pvesm','status']]:
            try: log('host-inventory',command=cmd,output=command(cmd))
            except Exception as ex: log('inventory-error',error=str(ex))
    if a.targets!='all':
        wanted=a.targets.split(',')
        if any(t not in targets for t in wanted): ap.error('unknown/nonlocal target; choose from '+','.join(targets))
        targets=[t for t in targets if t in wanted]
    targets=[t for t in targets if t not in a.exclude_target]
    failures=0
    for target in targets:
        print('\n['+target+']')
        if target != 'host':
            kind, ident = target.split(':')
            tool = 'pct' if kind == 'ct' else 'qm'
            for suffix in [['config', ident], ['listsnapshot', ident]]:
                try: log('protected-guest-inventory',target=target,command=[tool]+suffix,output=command([tool]+suffix))
                except Exception as ex: log('inventory-error',target=target,error=str(ex))
        request={'mode':'scan','days':a.journal_days,'exclude_paths':[os.path.normpath(p) for p in a.exclude_path]}
        try:
            result=json.loads(worker(target,request))
            log('scan',target=target,result=result)
            if 'error' in result: raise RuntimeError(result['error'])
            print(result['df'].strip())
            for note in result['notes']: print('skip: '+note)
            items=result['candidates']
            for i,item in enumerate(items,1): print(f"{i:3} {item['action']:7} {item['fingerprint'][2]:12,d} bytes  {item['path']}")
            print(f'{len(items)} verified candidates; {sum(x["fingerprint"][2] for x in items):,} logical bytes (not a storage savings estimate)')
            if not a.apply or not items: continue
            print('Select exact file numbers separated by commas; Enter skips this target.')
            selection=input('allowlist> ').strip()
            if not selection: continue
            indices=selection.split(',')
            if any(not x.isdigit() or not 1<=int(x)<=len(items) for x in indices): raise RuntimeError('invalid selection; target skipped')
            chosen=[items[i-1] for i in sorted(set(map(int,indices)))]
            for item in chosen: print('DELETE '+item['path'])
            print('Confirm current backups/recovery have been reviewed. Deleted logs cannot be reconstructed from this report.')
            token='delete '+target
            if input('Type "'+token+'" to authorize these exact files> ')!=token:
                log('declined',target=target); continue
            log('authorized',target=target,allowlist=chosen)
            request.update(mode='apply',items=chosen)
            output=worker(target,request)
            log('apply-result',target=target,output=output)
            print(output)
        except KeyboardInterrupt:
            log('interrupted',target=target); print('Interrupted; inspect report and guest status before retrying.'); return 130
        except Exception as ex:
            failures+=1; log('target-error',target=target,error=str(ex)); print('SKIPPED/FAILED: '+str(ex))
    log('finish',failures=failures)
    print('\nreport: '+str(report))
    return 1 if failures else 0

if __name__=='__main__':
    sys.exit(main())
