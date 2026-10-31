"""Exercise the actual Bash wizard with fake UI/Proxmox commands."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/proxmox-debian-lxc-create.sh'
GUARD = 'if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]:-}" == "$0" ]]; then main "$@"; fi'


class WorkflowTests(unittest.TestCase):
    def exercise(self, scenario='normal', execute=False):
        with tempfile.TemporaryDirectory() as directory:
            d = Path(directory)
            (d / 'bridge').mkdir()
            (d / 'lxc' / '204').mkdir(parents=True)
            source = SCRIPT.read_text().replace(GUARD, '')
            source = source.replace('/var/lib/lxc/', str(d / 'lxc') + '/')
            source = source.replace('exec > >(tee -a "$LOG") 2>&1', 'exec >>"$LOG" 2>&1')
            source = source.replace('/var/log/sweenlab-debian-lxc', str(d / 'logs'))
            source = source.replace('"/sys/class/net/$bridge/bridge"', '"' + str(d / 'bridge') + '"')
            source = source.replace('[[ -c /dev/net/tun ]]', '[[ -c /dev/null ]]')
            source = source.replace('[[ -c "$device" ]]', '[[ -c /dev/null ]]')
            source = source.replace('>/dev/tty 2>/dev/tty', '>"' + str(d / 'auth-output') + '" 2>&1')
            (d / 'wizard.sh').write_text(source)
            env = dict(os.environ, FIXTURE=str(d), SCENARIO=scenario)
            code = '''source "$FIXTURE/wizard.sh"
gpu_names=''
[[ $SCENARIO != gpu-required ]] || gpu_names=/dev/dri/renderD128
UI_DIR=$FIXTURE/ui; mkdir -p "$UI_DIR"
nproc() { echo 8; }
dpkg() { echo amd64; }
timedatectl() { echo UTC; }
pvesh() {
    if [[ "$2" == */lxc/*/config ]]; then
        python3 -c 'import json, os; from pathlib import Path; p=Path(os.environ["FIXTURE"])/"notes"; print(json.dumps({"description": p.read_text()+"\\n" if p.exists() else ""}))'
    elif [[ "$2" == */network ]]; then echo '[{"iface":"vmbr0","type":"bridge","active":1}]'
    else echo 204; fi
}
pvesm() { printf 'Name Type Status\\nlocal dir active\\nstorage4tb dir active\\n'; }
pveam() {
    [[ "$1" == list ]] || return 91
    printf 'NAME SIZE\\nlocal:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst 300MB\\nlocal:vztmpl/ubuntu-24.04.tar.zst 300MB\\n'
}
lxc-usernsexec() {
    printf 'namespace-probe\\n' >> "$FIXTURE/calls"
    [[ "$SCENARIO" != namespace-fail ]]
}
namei() { echo 'read-only path diagnostics'; }
findmnt() { echo 'read-only mount diagnostics'; }
pct() {
    printf 'pct' >> "$FIXTURE/calls"
    printf ' <%s>' "$@" >> "$FIXTURE/calls"
    printf '\\n' >> "$FIXTURE/calls"
    if [[ "$1" == create || "$1" == set ]]; then
        local previous='' argument
        for argument in "$@"; do
            [[ "$previous" != --description ]] || printf '%s' "$argument" > "$FIXTURE/notes"
            previous=$argument
        done
    fi
    if [[ "$1" == create && "$SCENARIO" == notes-dropped ]]; then rm -f "$FIXTURE/notes"; fi
    if [[ "$1" == set && "$SCENARIO" == notes-mismatch ]]; then printf 'unexpected notes' > "$FIXTURE/notes"; fi
    if [[ "$1" == set && "$SCENARIO" == notes-fail ]]; then return 17; fi
    if [[ "$1" == help ]]; then echo '--dev[n]'; fi
    if [[ "$1" == create && "$SCENARIO" == create-fail ]]; then echo 'tar: rootfs: Cannot open: Permission denied' >&2; return 255; fi
    if [[ "$1" == exec && "$*" == *chpasswd* ]]; then
        local credential
        IFS= read -r credential
        [[ "$credential" == 'root:fixture-secret' ]] || return 92
    fi
    if [[ "$1" == push ]]; then cp "$3" "$FIXTURE/guest.sh"; fi
    if [[ "$1" == exec && "$*" == *'tailscale up'* ]]; then echo 'SECRET-AUTH-URL'; [[ $SCENARIO != ts-fail ]] || return 1; fi
    if [[ "$1" == exec && "$*" == *'bash /root/sweenlab-debian-tools.sh'* && "$SCENARIO" == installer-fail ]]; then return 42; fi
    return 0
}
rewinding=0; visits_memory=0; visits_swap=0; visits_disk=0; visits_review=0; visits_password=0; visits_hostname=0; visits_selected=0; visits_ipmode=0; visits_gpu=0; visits_ip=0
ui() {
    printf '%s|%s|seed=%s|error=%s\\n' "$key" "$1" "$([[ "$key" == password* ]] && echo HIDDEN || printf '%s' "$4")" "$error" >> "$FIXTURE/trace"
    UI_ACTION=next; UI_VALUE=$4
    if (( rewinding )) && [[ $key != selected ]]; then UI_ACTION=back; return; fi
    [[ ( $SCENARIO != verbose && $SCENARIO != ts-fail ) || $key != verbose ]] || UI_VALUE=1
    [[ "$SCENARIO" != abort ]] || { UI_ACTION=abort; return; }
    case "$key" in
        ip) visits_ip=$((visits_ip+1)); [[ "$4" != dhcp ]] || exit 94; UI_VALUE=10.10.10.204/24; if [[ $SCENARIO == missing-cidr && $visits_ip == 1 ]]; then UI_VALUE=10.10.10.204; fi;;
        locale_name) UI_VALUE=en_GB.UTF-8;;
        hostname) visits_hostname=$((visits_hostname+1)); UI_VALUE=test-debian
            if [[ "$SCENARIO" == mandatory && "$visits_hostname" == 1 ]]; then UI_VALUE=''; fi;;
        bridge) UI_VALUE=vmbr0;;
        ipmode) visits_ipmode=$((visits_ipmode+1)); UI_VALUE=static; if [[ $SCENARIO == missing-network && $visits_ipmode == 1 ]]; then UI_VALUE=''; fi;;
        ip6mode) UI_VALUE=manual;;
        gpu) UI_VALUE=1;;
        gpu_selected) visits_gpu=$((visits_gpu+1)); if (( visits_gpu == 1 )); then UI_VALUE=''; else UI_VALUE=/dev/dri/renderD128; fi;;
        gateway) UI_VALUE=10.10.10.1;;
        root_store) UI_VALUE=storage4tb;;
        template_store) UI_VALUE=local;;
        template) UI_VALUE=local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst;;
        memory) visits_memory=$((visits_memory+1));
            if [[ "$SCENARIO" == back && "$visits_memory" == 2 && "$4" != 4096 ]]; then exit 93; fi
            UI_VALUE=4096;;
        swap) visits_swap=$((visits_swap+1)); UI_VALUE=2048
            if [[ $SCENARIO == swap-zero ]]; then UI_VALUE=0; fi
            if [[ $SCENARIO == swap-invalid && $visits_swap -le 4 ]]; then
                case $visits_swap in 1) UI_VALUE='';; 2) UI_VALUE=-1;; 3) UI_VALUE=1.5;; 4) UI_VALUE=1048577;; esac
            fi
            if [[ $SCENARIO == back && $visits_swap == 1 ]]; then UI_ACTION=back; fi
            if [[ $SCENARIO == swap-back && $visits_swap == 2 && $4 != 2048 ]]; then exit 96; fi;;
        disk) visits_disk=$((visits_disk+1));
            if [[ "$SCENARIO" == swap-back && "$visits_disk" == 1 ]]; then UI_ACTION=back; fi;;
        password) visits_password=$((visits_password+1)); UI_VALUE=fixture-secret
            if [[ "$SCENARIO" == mandatory && "$visits_password" == 1 ]]; then UI_VALUE=''; fi;;
        password_confirm) [[ -z $4 ]] || exit 95; UI_VALUE=fixture-secret;;
        selected) visits_selected=$((visits_selected+1)); if [[ "$SCENARIO" == no-packages ]]; then if (( visits_selected == 1 )); then UI_VALUE=''; else UI_VALUE=__none__; fi; elif [[ $SCENARIO == no-tailscale || ( $SCENARIO == removed-tailscale && $visits_selected -gt 1 ) ]]; then UI_VALUE=$'git\\ncompose'; else UI_VALUE=$'git\\ncompose\\ntailscale'; fi; rewinding=0;;
        review) visits_review=$((visits_review+1));
            printf '%s' "$3" > "$FIXTURE/review"
            if [[ $SCENARIO == removed-tailscale && $visits_review == 1 ]]; then rewinding=1; UI_ACTION=back; fi
            if [[ "$SCENARIO" == back && "$visits_review" == 1 ]]; then UI_ACTION=back; fi;;
    esac
}
configure
'''
            code += '\nexecute_plan\n' if execute else '\nprintf "CONFIGURED %s %s %s\\n" "$hostname" "$memory" "$tz"\n'
            result = subprocess.run(['bash', '-c', code], env=env, text=True, capture_output=True)
            files = {str(p.relative_to(d)): p.read_text() for p in d.rglob('*') if p.is_file()}
            return result, files

    def test_back_preserves_values_and_review_can_go_back(self):
        result, files = self.exercise('back')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('CONFIGURED test-debian 4096 UTC', result.stdout)
        trace = files['trace']
        self.assertEqual(trace.count('memory|'), 2)
        self.assertEqual(sum(line.startswith('review|') for line in trace.splitlines()), 2)
        self.assertNotIn('fixture-secret', trace)
        self.assertNotIn('calls', files)

    def test_required_hostname_and_password_block_advancement(self):
        result, files = self.exercise('mandatory')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(files['trace'].count('hostname|'), 2)
        self.assertEqual(sum(line.startswith('password|') for line in files['trace'].splitlines()), 2)
        self.assertIn('A root password is required.', files['trace'])

    def test_empty_selection_requires_explicit_none(self):
        result, files = self.exercise('no-packages')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Choose at least one package', files['trace'])
        self.assertNotIn('ts_options|', files['trace'])
        self.assertNotIn('ts_up|', files['trace'])
        self.assertIn('Packages        None', files['review'])

    def test_abort_does_not_create_anything(self):
        result, files = self.exercise('abort', execute=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('calls', files)
        self.assertNotIn('guest.sh', files)

    def test_background_defaults_cached_template_and_tailscale_flags(self):
        result, files = self.exercise(execute=True)
        self.assertEqual(result.returncode, 0, (result.stdout, result.stderr, files))
        calls = files['calls']
        self.assertIn('<--cpulimit> <0> <--cpuunits> <100>', calls)
        self.assertIn('<--swap> <2048>', calls)
        self.assertIn('swap|input|seed=|', files['trace'])
        self.assertIn('Swap            2048 MiB', files['review'])
        for key in ('bridge', 'ipmode', 'ip6mode', 'root_store', 'template_store', 'template'):
            self.assertIn(key + '|select|', files['trace'])
        self.assertIn('ipmode|select|seed=|', files['trace'])
        self.assertIn('ip6mode|select|seed=|', files['trace'])
        self.assertIn('<--rootfs> <storage4tb:10>', calls)
        self.assertIn('<--onboot> <1> <--protection> <0>', calls)
        self.assertNotIn('<--startup>', calls)
        self.assertIn('firewall=1,mtu=1500', calls)
        for argument in ('tag=', 'hwaddr=', 'rate=', '<--nameserver>', '<--searchdomain>'):
            self.assertNotIn(argument, calls)
        self.assertIn('nesting=1,fuse=0,keyctl=1', calls)
        self.assertIn('path=/dev/net/tun,gid=0,uid=0,mode=0660', calls)
        self.assertIn('<--upgrade> <1>', calls)
        self.assertIn('<--locale> <en_GB.UTF-8>', calls)
        self.assertIn('verbose|yesno|seed=0', files['trace'])
        self.assertIn('fuse|yesno|seed=0', files['trace'])
        self.assertIn('tun|yesno|seed=1', files['trace'])
        self.assertIn('<tailscale> <up> <--timeout=120s> <--ssh=true> <--accept-dns=false> <--accept-routes=false> <--qr=false>', calls)
        self.assertIn('SECRET-AUTH-URL', files['auth-output'])
        logs = '\n'.join(value for key, value in files.items() if key.startswith('logs/'))
        self.assertNotIn('SECRET-AUTH-URL', logs)
        self.assertNotIn('fixture-secret', logs)
        self.assertIn('pveam', SCRIPT.read_text())
        self.assertNotIn('Refresh the Proxmox template catalog', files['trace'])
        for removed in ('cpulimit|', 'cpuunits|', 'protection|', 'startup|', 'upgrade|', 'vlan|', 'mtu|', 'mac|', 'rate|', 'dns|', 'search|'):
            self.assertNotIn('\n' + removed, '\n' + files['trace'])

    def test_tun_is_hidden_and_not_passed_without_tailscale(self):
        for scenario in ('no-tailscale', 'no-packages'):
            with self.subTest(scenario=scenario):
                result, files = self.exercise(scenario, execute=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn('tun|yesno|', files['trace'])
                self.assertNotIn('path=/dev/net/tun', files['calls'])
                self.assertIn('FUSE / TUN      No / No', files['review'])

    def test_removing_tailscale_via_back_clears_tun(self):
        result, files = self.exercise('removed-tailscale', execute=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('tun|yesno|seed=1', files['trace'])
        self.assertIn('FUSE / TUN      No / No', files['review'])
        self.assertNotIn('path=/dev/net/tun', files['calls'])

    def test_verbose_ends_with_completed_checklist(self):
        result, files = self.exercise('verbose', execute=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        logs = '\n'.join(value for key, value in files.items() if key.startswith('logs/'))
        self.assertIn('── Completed · CT 204 (test-debian) ──', logs)
        summary = logs.split('── Completed', 1)[1]
        for text in ('✅ Locale en_GB.UTF-8 configured', '✅ Debian full upgrade completed', '✅ Selected tool installed: git', '✅ Tailscale sign-in completed'):
            self.assertIn(text, summary)
        self.assertNotIn('[..]', logs)
        self.assertIn('<env> <LANG=C.UTF-8> <LC_ALL=C.UTF-8>', files['calls'])

    def test_incomplete_login_is_not_checked_off(self):
        result, files = self.exercise('ts-fail', execute=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        logs = '\n'.join(value for key, value in files.items() if key.startswith('logs/'))
        summary = logs.split('── Completed', 1)[1]
        self.assertIn('⚠ Tailscale sign-in is incomplete.', summary)
        self.assertNotIn('✅ Tailscale sign-in completed', summary)

    def test_missing_network_mode_is_rejected_before_continuing(self):
        result, files = self.exercise('missing-network')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Select an IPv4 mode.', files['trace'])
        self.assertEqual(files['trace'].count('ipmode|select|'), 2)

    def test_enabling_gpu_requires_a_device(self):
        result, files = self.exercise('gpu-required')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Select at least one GPU device', files['trace'])
        self.assertIn('/dev/dri/renderD128', files['review'])

    def test_static_ipv4_without_cidr_cannot_advance(self):
        result, files = self.exercise('missing-cidr')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('CIDR is required', files['trace'])
        self.assertEqual(files['trace'].count('ip|input|'), 2)
        self.assertIn('IPv4            10.10.10.204/24', files['review'])

    def test_ipv4_cidr_validator_requires_numeric_prefix(self):
        for address, valid in [('10.10.10.204/24', True), ('10.0.0.1/0', True), ('10.0.0.1/32', True),
                               ('10.10.10.204', False), ('', False), ('10.0.0.1/33', False),
                               ('10.0.0.1/255.255.255.0', False), ('999.0.0.1/24', False),
                               ('10.0.0.1/', False), ('10.0.0.1/abc', False)]:
            with self.subTest(address=address):
                result = subprocess.run(['bash', '-c', 'source "$1"; validate_ip 4 "$2"', 'test', str(SCRIPT), address], capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, valid, result.stderr)

    def test_creation_sets_generic_centered_notes_as_one_argument(self):
        result, files = self.exercise(execute=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        notes = files['notes']
        self.assertIn('<table width="100%" height="280">', notes)
        self.assertIn('align="center" valign="middle"', notes)
        self.assertIn('sweenlab-scripts-notes.png', notes)
        for label in ('>GitHub</a>', '>Guide</a>', '>Releases</a>'):
            self.assertIn(label, notes)
        for private in ('fixture-secret', 'test-debian', 'Dockhand', 'Apprise', '10.10.10.204'):
            self.assertNotIn(private, notes)
        self.assertLess(len(notes.encode()), 8192)
        self.assertIn('pct <set> <204> <--description>', files['calls'])
        self.assertIn('Save and verify Summary notes', '\n'.join(v for k, v in files.items() if k.startswith('logs/')))

    def test_swap_zero_disables_swap(self):
        result, files = self.exercise('swap-zero', execute=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('<--swap> <0>', files['calls'])

    def test_swap_rejects_blank_negative_fraction_and_out_of_range(self):
        result, files = self.exercise('swap-invalid', execute=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(files['trace'].count('swap|input|'), 5)
        self.assertIn('Enter swap in whole MiB', files['trace'])
        self.assertIn('<--swap> <2048>', files['calls'])

    def test_swap_is_preserved_on_back(self):
        result, files = self.exercise('swap-back')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(files['trace'].count('swap|input|'), 2)
        self.assertIn('swap|input|seed=2048|', files['trace'])

    def test_notes_are_restored_if_creation_drops_description(self):
        result, files = self.exercise('notes-dropped', execute=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('sweenlab-scripts-notes.png', files['notes'])
        self.assertIn('pct <set> <204> <--description>', files['calls'])

    def test_notes_failure_or_readback_mismatch_cannot_report_success(self):
        for scenario in ('notes-fail', 'notes-mismatch'):
            with self.subTest(scenario=scenario):
                result, files = self.exercise(scenario, execute=True)
                self.assertNotEqual(result.returncode, 0)
                logs = '\n'.join(v for k, v in files.items() if k.startswith('logs/'))
                self.assertNotIn('created and selected packages installed.', logs)
                self.assertNotIn('pct <destroy>', files['calls'])

    def test_namespace_failure_happens_before_pct_create(self):
        result, files = self.exercise('namespace-fail', execute=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('pct <create>', files['calls'])
        logs = '\n'.join(value for key, value in files.items() if key.startswith('logs/'))
        self.assertIn('cannot traverse', logs)
        self.assertNotIn('chmod', files['calls'])

    def test_creation_failure_preserves_state_and_prints_diagnostics(self):
        result, files = self.exercise('create-fail', execute=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('pct <start>', files['calls'])
        self.assertNotIn('pct <destroy>', files['calls'])
        logs = '\n'.join(value for key, value in files.items() if key.startswith('logs/'))
        self.assertIn('Read-only path diagnostics', logs)
        self.assertIn('status 255', logs)

    def test_installer_failure_preserves_the_created_ct(self):
        result, files = self.exercise('installer-fail', execute=True)
        self.assertEqual(result.returncode, 42)
        self.assertIn('pct <start>', files['calls'])
        self.assertNotIn('pct <destroy>', files['calls'])


if __name__ == '__main__':
    unittest.main()
