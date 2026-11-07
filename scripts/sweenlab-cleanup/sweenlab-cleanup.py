#!/usr/bin/env python3
"""sweenlab | conservative Proxmox inventory and reviewed cache cleanup."""
import argparse
import contextlib
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
SCRIPT_VERSION = "0.2.0"

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


import curses
import os
import re
import sys
import textwrap


def button_set(kind):
    if kind == 'yesno':
        return [('Back', 'back', ''), ('Yes', 'next', '1'), ('No', 'next', '0'), ('Abort', 'abort', '')]
    if kind == 'notice':
        return [('Back', 'back', ''), ('Abort', 'abort', '')]
    return [('Back', 'back', ''), ('Next', 'next', None), ('Abort', 'abort', '')]


def review_rows(prompt, width):
    rows = []
    for raw in prompt.splitlines():
        line = raw.strip()
        if not line:
            rows.append(('', '', 'space'))
        elif line.isupper():
            rows.append((line, '', 'section'))
        else:
            fields = re.split(r'\s{2,}', line, maxsplit=1)
            if len(fields) == 2:
                label, value = fields
                for idx, part in enumerate(textwrap.wrap(value, max(12, width - 21)) or ['']):
                    rows.append((label if idx == 0 else '', part, 'value'))
            else:
                rows.extend((part, '', 'note') for part in textwrap.wrap(line, width))
    return rows


def run(screen, kind, title, prompt, seed, options):
    curses.curs_set(0)
    screen.keypad(True)
    accent = success = highlight = body = field = 0
    try:
        if curses.has_colors() and not os.environ.get('NO_COLOR'):
            curses.start_color()
            curses.use_default_colors()
            curses.init_pair(1, 208 if curses.COLORS >= 256 else curses.COLOR_YELLOW, -1)
            curses.init_pair(2, 114 if curses.COLORS >= 256 else curses.COLOR_GREEN, -1)
            curses.init_pair(3, curses.COLOR_BLACK, 114 if curses.COLORS >= 256 else curses.COLOR_GREEN)
            curses.init_pair(4, 252 if curses.COLORS >= 256 else curses.COLOR_WHITE, -1)
            curses.init_pair(5, 252 if curses.COLORS >= 256 else curses.COLOR_WHITE, 236 if curses.COLORS >= 256 else curses.COLOR_BLACK)
            accent, success, highlight, body, field = (curses.color_pair(i) for i in (1, 2, 3, 4, 5))
            screen.bkgd(' ', body)
    except curses.error:
        pass
    text = '' if kind == 'password' else seed
    cursor = len(text)
    tags = [tag for tag, _ in options]
    selected = set(seed.splitlines())
    choice = seed if seed in tags else ''
    selection_error = ''
    row = tags.index(seed) if seed in tags else 0
    scroll = 0
    buttons = button_set(kind)
    if kind == 'review' and title.endswith('Delete selected files'):
        buttons = [('Back', 'back', ''), ('Delete files', 'next', None), ('Abort', 'abort', '')]
    button = 0 if title.endswith('Delete selected files') else (1 if kind != 'notice' else 0)
    if kind == 'yesno' and seed == '0':
        button = 2
    focus = 'buttons' if kind in ('yesno', 'review', 'notice') else 'content'
    while True:
        screen.erase()
        h, w = screen.getmaxyx()
        if h < 24 or w < 80:
            screen.addnstr(0, 0, 'Enlarge this terminal to at least 80 columns x 24 rows. Esc aborts.', max(1, w - 1))
            screen.refresh()
            if screen.getch() == 27:
                return 'abort', ''
            continue
        width = min(w - 4, 100)
        left = (w - width) // 2
        top = 1
        height = h - 2
        box = screen.derwin(height, width, top, left)
        box.bkgd(' ', body)
        box.box()
        def write(y, x, value, attr=0):
            if 0 <= y < height - 1:
                if x == 3:
                    value = value.strip()
                    x = max(2, (width - min(len(value), width - 6)) // 2)
                box.addnstr(y, x, value, max(0, width - x - 2), attr)
        write(0, max(2, (width - len(title) - 2) // 2), ' ' + title + ' ', curses.A_BOLD | accent)
        lines = []
        for paragraph in prompt.splitlines():
            lines.extend(textwrap.wrap(paragraph, width - 6) or [''])
        if kind == 'review':
            table_width = min(width - 10, 76)
            table_x = (width - table_width) // 2
            rows = review_rows(prompt, table_width)
            limit = height - 7
            scroll = max(0, min(scroll, max(0, len(rows) - limit)))
            for idx, (label, value, role) in enumerate(rows[scroll:scroll + limit]):
                y = 2 + idx
                if role == 'section':
                    box.addnstr(y, table_x, label + ' ' + '─' * max(0, table_width - len(label) - 1), table_width, accent | curses.A_BOLD)
                elif role == 'value':
                    box.addnstr(y, table_x, label, 19, success)
                    box.addnstr(y, table_x + 21, value, table_width - 21, body)
                else:
                    box.addnstr(y, table_x, label, table_width, body)
        else:
            block_height = min(len(lines), 8) + 1 + (min(len(options), max(1, height - min(len(lines), 8) - 8)) if kind in ('menu', 'check', 'select') else 1)
            prompt_y = max(2, 2 + (height - 7 - block_height) // 2)
            required = '(required)' in title
            for idx, line in enumerate(lines[:8]):
                conversions = re.findall(r'(\d+)\s+GiB\s*=\s*(\d+)', line)
                if len(conversions) == 4:
                    # Keep labels neutral; emphasize only the values to enter.
                    cell_width, gap = 14, 3
                    grid_x = (width - (4 * cell_width + 3 * gap)) // 2
                    for column, (gib, mib) in enumerate(conversions):
                        x = grid_x + column * (cell_width + gap)
                        box.addnstr(prompt_y + idx, x, f'{gib:>2} GiB = ', 9, body)
                        box.addnstr(prompt_y + idx, x + 9, f'{mib:>5}', 5, success | curses.A_BOLD)
                        if column < 3:
                            box.addnstr(prompt_y + idx, x + cell_width, ' │ ', gap, body | curses.A_DIM)
                else:
                    style = (body | curses.A_BOLD) if line.startswith('Memory in MiB') else success | (curses.A_BOLD if required else 0)
                    write(prompt_y + idx, 3, line, style)
            content_y = prompt_y + 1 + min(len(lines), 8)
            if kind in ('input', 'password'):
                shown = '*' * len(text) if kind == 'password' else text
                field_width = min(48, width - 12)
                offset = max(0, cursor - field_width + 1)
                field_left = (width - field_width - 4) // 2
                field_x = field_left + 2
                box.addnstr(content_y, field_left, '[ ' + ' ' * field_width + ' ]', field_width + 4, field)
                box.addnstr(content_y, field_x, shown[offset:offset + field_width], field_width, field | (curses.A_BOLD if required else 0))
            elif kind in ('menu', 'check', 'select'):
                visible = max(1, height - content_y - 5)
                start = max(0, min(row - visible + 1, max(0, len(options) - visible)))
                for idx, (tag, label) in enumerate(options[start:start + visible], start):
                    checked = (set(tags) - {'__all__', '__none__'} <= selected) if tag == '__all__' else tag in selected
                    mark = ('[x] ' if checked else '[ ] ') if kind == 'check' else (('(x) ' if tag == choice else '( ) ') if kind == 'select' else '')
                    label = (label or tag) if kind in ('menu', 'select') or tag in ('__all__', '__none__') else (tag if not label else tag + '  ' + label)
                    write(content_y + idx - start, 3, mark + label,
                          ((highlight or curses.A_REVERSE) if idx == row and focus == 'content' else success) | (curses.A_BOLD if required else 0))
        labels = ['< ' + value[0] + ' >' for value in buttons]
        total = sum(map(len, labels)) + 4 * (len(labels) - 1)
        x = max(2, (width - total) // 2)
        for idx, label in enumerate(labels):
            write(height - 4, x, label, (highlight or curses.A_REVERSE) | curses.A_BOLD if idx == button and focus == 'buttons' else accent)
            x += len(label) + 4
        hint = 'Up/Down: field/buttons | Left/Right: edit/choose | Enter: confirm | Esc: abort'
        if kind == 'check':
            hint = 'Arrows: navigate | Right: buttons | Space: select | Enter: next | Esc: abort'
        if kind == 'select':
            hint = 'Up/Down: highlight | Space/Enter: select → Next | Tab: buttons | Esc: abort'
        if selection_error:
            write(height - 3, 3, selection_error, accent | curses.A_BOLD)
        if kind == 'review':
            hint = f'{scroll + 1}-{min(scroll + limit, len(rows))}/{len(rows)} | Up/Down: scroll | Left/Right: buttons | Esc: abort'
        write(height - 2, 3, hint, curses.A_DIM)
        curses.curs_set(1 if focus == 'content' and kind in ('input', 'password') else 0)
        if focus == 'content' and kind in ('input', 'password'):
            box.move(content_y, field_x + min(cursor - offset, field_width - 1))
        box.refresh()
        key = screen.get_wch()
        if key == '\x1b' or key == '\x03':
            return 'abort', ''
        if key == curses.KEY_RESIZE:
            continue
        if key in ('\t', curses.KEY_BTAB):
            if focus == 'content':
                focus = 'buttons'
                button = len(buttons) - 1 if key == curses.KEY_BTAB else 0
            else:
                step = -1 if key == curses.KEY_BTAB else 1
                target = button + step
                if target < 0 or target >= len(buttons):
                    if kind in ('input', 'password', 'menu', 'check', 'select'):
                        focus = 'content'
                    else:
                        button = target % len(buttons)
                else:
                    button = target
            continue
        if kind == 'review' and key in (curses.KEY_UP, curses.KEY_DOWN, curses.KEY_NPAGE, curses.KEY_PPAGE):
            scroll += {curses.KEY_UP: -1, curses.KEY_DOWN: 1, curses.KEY_NPAGE: 8, curses.KEY_PPAGE: -8}[key]
            continue
        if kind in ('input', 'password', 'menu', 'check', 'select'):
            if focus == 'buttons' and key == curses.KEY_UP:
                focus = 'content'
                continue
            if focus == 'content' and kind in ('input', 'password') and key in (curses.KEY_UP, curses.KEY_DOWN):
                focus, button = 'buttons', 1
                continue
            if focus == 'content' and kind in ('menu', 'check', 'select') and key == curses.KEY_RIGHT:
                focus, button = 'buttons', 1
                continue
        if kind == 'yesno' and key in (curses.KEY_UP, curses.KEY_DOWN):
            button = (button + (1 if key == curses.KEY_DOWN else -1)) % len(buttons)
            continue
        if focus == 'buttons' and key in (curses.KEY_LEFT, curses.KEY_RIGHT):
            button = (button + (1 if key == curses.KEY_RIGHT else -1)) % len(buttons)
            continue
        if focus == 'content':
            if kind in ('menu', 'check', 'select'):
                if key in (curses.KEY_UP, curses.KEY_DOWN):
                    target = row + (1 if key == curses.KEY_DOWN else -1)
                    if target < 0 or target >= len(options):
                        focus, button = 'buttons', 1
                    else:
                        row = target
                    continue
                if kind == 'select' and key in (' ', '\n', '\r', curses.KEY_ENTER):
                    choice = tags[row] if tags else ''
                    selection_error = ''
                    if choice:
                        focus, button = 'buttons', 1
                    continue
                if key == ' ' and kind == 'check' and options:
                    selection_error = ''
                    tag = options[row][0]
                    if tag == '__all__':
                        all_tags = set(tags) - {'__all__', '__none__'}
                        selected.discard('__none__')
                        if all_tags <= selected:
                            selected -= all_tags
                        else:
                            selected |= all_tags
                            focus, button = 'buttons', 1
                    elif tag == '__none__':
                        selected = set() if '__none__' in selected else {'__none__'}
                    elif '__none__' not in selected:
                        selected.symmetric_difference_update([tag])
                    continue
            elif kind in ('input', 'password'):
                if key in (curses.KEY_BACKSPACE, '\x7f', '\b'):
                    if cursor:
                        text = text[:cursor - 1] + text[cursor:]
                        cursor -= 1
                    continue
                if key == curses.KEY_DC:
                    text = text[:cursor] + text[cursor + 1:]
                    continue
                if key in (curses.KEY_LEFT, curses.KEY_RIGHT, curses.KEY_HOME, curses.KEY_END):
                    cursor = {curses.KEY_LEFT: max(0, cursor - 1), curses.KEY_RIGHT: min(len(text), cursor + 1),
                              curses.KEY_HOME: 0, curses.KEY_END: len(text)}[key]
                    continue
                if key == '\x15':
                    text, cursor = '', 0
                    continue
                if isinstance(key, str) and key.isprintable():
                    text = text[:cursor] + key + text[cursor:]
                    cursor += 1
                    continue
        if key in ('\n', '\r', curses.KEY_ENTER):
            _, action, value = buttons[button if focus == 'buttons' else 1]
            if action != 'next' or value is not None:
                return action, value or ''
            if kind in ('input', 'password'):
                return action, text
            if kind == 'select':
                if choice not in tags:
                    selection_error = 'Select one option before continuing.'
                    focus = 'content'
                    continue
                return action, choice
            if kind == 'menu':
                return action, tags[row] if tags else ''
            if kind == 'check':
                if '(required)' in title and not any(tag in selected for tag in tags if tag != '__all__'):
                    selection_error = 'Select at least one option before continuing.'
                    focus = 'content'
                    continue
                return action, '\n'.join(tag for tag in tags if tag in selected and tag != '__all__')
            return action, ''




class WizardAbort(Exception):
    pass


class WindowUI:
    """The LXC creator's embedded curses renderer; no packages are installed."""
    def ask(self, kind, title, prompt, seed='', options=()):
        action, value = curses.wrapper(run, kind, 'SweenLab '+SCRIPT_VERSION+' | '+title, prompt, seed, options)
        if action == 'abort':
            raise WizardAbort()
        return action, value

    def working(self, title, callback):
        def display(screen):
            curses.curs_set(0)
            screen.erase()
            h, w = screen.getmaxyx()
            accent = success = 0
            if curses.has_colors() and not os.environ.get('NO_COLOR'):
                curses.start_color(); curses.use_default_colors()
                curses.init_pair(1, 208 if curses.COLORS >= 256 else curses.COLOR_YELLOW, -1)
                curses.init_pair(2, 114 if curses.COLORS >= 256 else curses.COLOR_GREEN, -1)
                accent, success = curses.color_pair(1), curses.color_pair(2)
            screen.box()
            for y, text, style in [(2, 'SweenLab '+SCRIPT_VERSION+' | '+title, accent | curses.A_BOLD),
                                   (h//2, 'Working... please wait for the result.', success),
                                   (h//2+2, 'Do not close the terminal or retry during guest execution.', 0)]:
                if 0 < y < h-1:
                    screen.addnstr(y, max(1, (w-len(text))//2), text, max(1,w-2), style)
            screen.refresh()
            return callback()
        return curses.wrapper(display)

    def message(self, title, text):
        # Review layout wraps and scrolls the full text rather than clipping it.
        return self.ask('review', title, text)


def setup_windows(ui, a, targets, labels):
    """Back preserves setup values. No cleaning occurs in setup."""
    mode = 'apply' if a.apply else 'scan'
    selected = list(targets)
    exclusions = ';'.join(a.exclude_path)
    days = str(a.journal_days)
    step = 0
    while True:
        if step == 0:
            action, value = ui.ask('select', 'Cleanup mode (required)',
                'Inventory only is the default. Reviewed cleanup still requires exact file selection and typed confirmation for every target.',
                mode, [('scan', 'Inventory only'), ('apply', 'Review files for cleanup')])
            if action == 'back': raise WizardAbort()
            mode = value
        elif step == 1:
            action, value = ui.ask('check', 'Targets (required)',
                'Choose which systems to inspect. Space toggles a target. No guest is started or mounted.',
                '\n'.join(selected), [(t, labels.get(t,t)) for t in targets])
            if action == 'next': selected = value.splitlines()
        elif step == 2:
            action, value = ui.ask('input', 'Protected paths',
                'Optional absolute exclusions inside EVERY target. Separate multiple paths with semicolons. Leave blank for none. Overlap skips the entire cache/log directory.', exclusions)
            if action == 'next':
                paths = [x.strip() for x in value.split(';') if x.strip()]
                if any(not x.startswith('/') or '..' in x.split('/') for x in paths):
                    ui.message('Invalid exclusion', 'Use absolute paths without .. components.'); continue
                exclusions = value
        elif step == 3:
            action, value = ui.ask('input', 'Journal retention (required)',
                'Minimum age in days for archived system journal FILES. At least 30 days. Active logs and user journals are never eligible.', days)
            if action == 'next':
                if not value.isdigit() or int(value) < 30:
                    ui.message('Invalid retention', 'Enter a whole number of days, at least 30.'); continue
                days = value
        else:
            action, _ = ui.message('Review scan',
                'MODE\n'+('Inventory only' if mode == 'scan' else 'Reviewed cleanup')+
                '\nTARGETS\n'+'\n'.join(selected)+'\nEXCLUSIONS\n'+(exclusions or 'None')+
                '\nRETENTION\n'+days+' days\nPROTECTIONS\nNo disk, volume, backup, snapshot, mount, user file or trash deletion actions. Next starts inspection only. No files are selected for deletion.')
            if action == 'next':
                a.apply = mode == 'apply'
                a.exclude_path = [x.strip() for x in exclusions.split(';') if x.strip()]
                a.journal_days = int(days)
                return selected
        if action == 'back': step = max(0, step-1)
        else: step += 1


def review_files(ui, target, items):
    """Empty initial allowlist; full path review and two separate confirmations."""
    seed = ''
    while True:
        action, value = ui.ask('check', 'Select files | '+target,
            'No files are preselected. Space toggles a file. Next reviews the full paths. Leave all unchecked to skip this target.', seed,
            [(str(i), f"{x['action']} | {x['fingerprint'][2]:,} bytes | "+json.dumps(x['path'])) for i,x in enumerate(items,1)])
        if action == 'back': return []
        seed = value
        if not value: return []
        tags = value.splitlines()
        # Validate UI output before indexing. It can never become a command or path.
        if any(not tag.isdigit() or not 1<=int(tag)<=len(items) for tag in tags):
            raise RuntimeError('invalid file selection')
        chosen = [items[i-1] for i in sorted(set(map(int,tags)))]
        paths = '\n'.join(json.dumps(x['path']) for x in chosen)
        action,_ = ui.message('Review selected files | '+target,
            f'EXACT FILE ALLOWLIST\n{paths}\nTOTAL\n{len(chosen)} files. Logical bytes are not guaranteed physical savings.\nOnly these reviewed files can be deleted.')
        if action == 'back': continue
        action,ack = ui.ask('check', 'Recovery review (required)',
            'Review current backups and recovery before deleting. Selected journal archives cannot be recovered from the audit report. Snapshots may retain blocks and are not backups.', '',
            [('reviewed', 'I reviewed recovery and accept deletion of these exact files')])
        if action == 'back': continue
        if ack != 'reviewed': continue
        token = 'delete '+target
        action,typed = ui.ask('input', 'Confirm target (required)',
            'Type exactly: '+token+'\nThis authorizes only the reviewed file allowlist. Nothing is deleted until the final Delete files action.', '')
        if action == 'back': continue
        if typed != token:
            ui.message('Confirmation did not match', 'Nothing was authorized or deleted. Review the file selection again.'); continue
        action,_ = ui.message('Delete selected files',
            'TARGET\n'+target+'\nEXACT FILE ALLOWLIST\n'+paths+
            '\nFINAL ACTION\nDelete files starts deletion after fresh eligibility and fingerprint checks. Back returns to selection. Abort stops the run. Default focus is Back.')
        if action == 'next': return chosen

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--version', action='version', version='sweenlab cleanup '+SCRIPT_VERSION)
    ap.add_argument('--ui', action='store_true', help='require the LXC-style window interface')
    ap.add_argument('--no-ui', action='store_true', help='use the original text interface')
    ap.add_argument('--apply', action='store_true', help='interactive reviewed cleanup; default is inventory')
    ap.add_argument('--in-guest', action='store_true', help='inspect this Debian guest only; no Proxmox tools')
    ap.add_argument('--targets', default='all', help='all or comma-separated host,ct:200,vm:100')
    ap.add_argument('--exclude-target', action='append', default=[])
    ap.add_argument('--exclude-path', action='append', default=[], help='absolute path; applies inside every target')
    ap.add_argument('--journal-days', type=int, default=30, help='minimum archived system journal file age, >=30')
    ap.add_argument('--reports', default='/var/log/sweenlab/cleanup')
    a = ap.parse_args()
    if a.ui and a.no_ui: ap.error('choose --ui or --no-ui')
    if a.ui and not (sys.stdin.isatty() and sys.stdout.isatty()): ap.error('--ui requires an interactive terminal')
    ui = WindowUI() if not a.no_ui and sys.stdin.isatty() and sys.stdout.isatty() else None
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
    with contextlib.ExitStack() as resources:
        lock = resources.enter_context(open(reportdir / '.lock', 'a'))
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
        report = reportdir / (stamp+'-'+str(os.getpid())+'.jsonl')
        audit = resources.enter_context(open(report, 'x', buffering=1))
        def log(event, **values):
            audit.write(json.dumps({'time':dt.datetime.now(dt.timezone.utc).isoformat(), 'event':event, **values})+'\n')
            audit.flush(); os.fsync(audit.fileno())
        log('start', options=vars(a), script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
        accent='\033[38;5;208m' if sys.stdout.isatty() else ''
        reset='\033[0m' if accent else ''
        print('\n'+accent+'sweenlab | cleanup review'+reset+'\n'+('reviewed cleanup' if a.apply else 'inventory only')+' | report: '+str(report))
        targets=['host']
        labels={'host':'host | Proxmox node' if not a.in_guest else 'host | this guest'}
        if not a.in_guest:
            for kind, tool in [('ct','pct'),('vm','qm')]:
                try:
                    listing=command([tool,'list']); log('guest-list',kind=kind,output=listing)
                    targets += [kind+':'+line.split()[0] for line in listing.splitlines()[1:] if line.split() and line.split()[0].isdigit()]
                    for line in listing.splitlines()[1:]:
                        parts=line.split()
                        if parts and parts[0].isdigit(): labels[kind+':'+parts[0]]=kind+':'+parts[0]+' | '+' '.join(parts[1:])
                except Exception as ex: log('discovery-error',kind=kind,error=str(ex)); print(str(ex))
            for cmd in [['pveversion','-v'],['pvesm','status']]:
                try: log('host-inventory',command=cmd,output=command(cmd))
                except Exception as ex: log('inventory-error',error=str(ex))
        if a.targets!='all':
            wanted=a.targets.split(',')
            if any(t not in targets for t in wanted): ap.error('unknown/nonlocal target; choose from '+','.join(targets))
            targets=[t for t in targets if t in wanted]
        targets=[t for t in targets if t not in a.exclude_target]
        if ui:
            try:
                targets = setup_windows(ui, a, targets, labels)
                log('wizard-options', options=vars(a), targets=targets)
            except WizardAbort:
                log('aborted', stage='setup'); print('Aborted. No cleanup started. Report: '+str(report)); return 0
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
                raw = ui.working('Inspecting '+target, lambda: worker(target,request)) if ui else worker(target,request)
                result=json.loads(raw)
                log('scan',target=target,result=result)
                if 'error' in result: raise RuntimeError(result['error'])
                print(result['df'].strip())
                for note in result['notes']: print('skip: '+note)
                items=result['candidates']
                for i,item in enumerate(items,1): print(f"{i:3} {item['action']:7} {item['fingerprint'][2]:12,d} bytes  {item['path']}")
                print(f'{len(items)} verified candidates; {sum(x["fingerprint"][2] for x in items):,} logical bytes (not a storage savings estimate)')
                if ui:
                    ui.message('Inventory | '+target, result['df']+'\nCANDIDATES\n'+str(len(items))+' verified files\n'+('\n'.join(json.dumps(x['path']) for x in items) or 'None')+'\nEXCLUSIONS / NOTES\n'+'\n'.join(result['notes']))
                if not a.apply or not items: continue
                if ui:
                    chosen = review_files(ui, target, items)
                    if not chosen:
                        log('declined',target=target); continue
                    log('authorized',target=target,allowlist=chosen)
                    request.update(mode='apply',items=chosen)
                    output=ui.working('Cleaning reviewed files | '+target, lambda: worker(target,request))
                    log('apply-result',target=target,output=output)
                    ui.message('Cleanup result | '+target, output)
                    continue
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
            except WizardAbort:
                log('aborted',target=target); print('Aborted; earlier authorized targets may already be cleaned. Report: '+str(report)); return 0
            except KeyboardInterrupt:
                log('interrupted',target=target); print('Interrupted; inspect report and guest status before retrying.'); return 130
            except Exception as ex:
                failures+=1; log('target-error',target=target,error=str(ex)); print('SKIPPED/FAILED: '+str(ex))
                if ui:
                    try: ui.message('Skipped / failed | '+target, str(ex)+'\nInspect report and current guest state before retrying.')
                    except WizardAbort:
                        log('aborted',target=target); return 1
        log('finish',failures=failures)
        if ui:
            try: ui.message('Finished', 'REPORT\n'+str(report)+'\nRESULT\n'+str(failures)+' failed/skipped targets. Inventory alone deletes nothing. Earlier authorized cleanup actions are recorded in the report.')
            except WizardAbort: pass
        print('\nreport: '+str(report))
        return 1 if failures else 0

if __name__=='__main__':
    sys.exit(main())
