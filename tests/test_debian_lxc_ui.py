"""Check the embedded terminal UI's actual rendering and key handling."""
import curses
import ast
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/proxmox-debian-lxc-create.sh'


class Screen:
    def __init__(self, keys):
        self.keys = iter(keys)
        self.drawn = []
        self.positions = []
    def keypad(self, value): pass
    def erase(self): pass
    def getmaxyx(self): return 24, 93
    def derwin(self, *args): return self
    def box(self): pass
    def bkgd(self, *args): pass
    def addnstr(self, y, x, value, n, *args):
        self.drawn.append(value[:n])
        self.positions.append((y, x, value[:n], args))
    def move(self, *args): pass
    def refresh(self): pass
    def get_wch(self): return next(self.keys)


class TerminalUiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        code = subprocess.run(['bash', '-c', 'source "$1"; write_ui', '--', str(SCRIPT)],
                              text=True, capture_output=True, check=True).stdout
        cls.folder = tempfile.TemporaryDirectory()
        path = Path(cls.folder.name) / 'ui.py'
        path.write_text(code)
        spec = importlib.util.spec_from_file_location('sweenlab_terminal_ui', path)
        cls.ui = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.ui)

    @classmethod
    def tearDownClass(cls): cls.folder.cleanup()

    def drive(self, kind, keys, seed='', options=()):
        screen = Screen(keys)
        with patch.object(curses, 'curs_set'), patch.object(curses, 'has_colors', return_value=False):
            result = self.ui.run(screen, kind, 'Test', 'Question', seed, options)
        return result, '\n'.join(screen.drawn)

    def test_horizontal_yes_no_and_default_yes(self):
        result, drawn = self.drive('yesno', ['\n'], '1')
        self.assertEqual(result, ('next', '1'))
        self.assertEqual([item[0] for item in self.ui.button_set('yesno')], ['Back', 'Yes', 'No', 'Abort'])
        for label in ('< Back >', '< Yes >', '< No >', '< Abort >'):
            self.assertIn(label, drawn)

    def test_yes_no_back_and_no_keys(self):
        self.assertEqual(self.drive('yesno', [curses.KEY_LEFT, '\n'], '1')[0], ('back', ''))
        self.assertEqual(self.drive('yesno', [curses.KEY_RIGHT, '\n'], '1')[0], ('next', '0'))

    def test_input_back_and_abort(self):
        self.assertEqual(self.drive('input', ['\t', '\n'], 'kept')[0], ('back', ''))
        self.assertEqual(self.drive('input', ['\x1b'])[0], ('abort', ''))

    def test_password_is_masked(self):
        result, drawn = self.drive('password', list('fixture-secret') + ['\n'], 'old-secret')
        self.assertEqual(result, ('next', 'fixture-secret'))
        self.assertNotIn('fixture-secret', drawn)
        self.assertIn('**************', drawn)

    def test_bridge_and_storage_names_have_no_descriptions(self):
        result, drawn = self.drive('menu', [curses.KEY_DOWN, '\n'], '', [('vmbr0', ''), ('vmbr1', '')])
        self.assertEqual(result, ('next', 'vmbr1'))
        self.assertIn('vmbr0', drawn)
        self.assertNotIn('Configured', drawn)
        self.assertNotIn('rootdir storage', drawn)

    def test_review_uses_create_with_back_and_abort(self):
        self.assertEqual([item[0] for item in self.ui.button_set('review')], ['Back', 'Create', 'Abort'])
        self.assertEqual(self.drive('review', [curses.KEY_DOWN, '\n'])[0], ('next', ''))

    def test_checkbox_preserves_initial_selections(self):
        result, _ = self.drive('check', [' ', '\n'], 'ssh\nignore-dns', [('ssh', 'SSH'), ('ignore-dns', 'Keep DNS')])
        self.assertEqual(result, ('next', 'ignore-dns'))

    def test_select_all_and_clear_all_excludes_action_from_result(self):
        options = [('__all__', 'Select all / clear all'), ('git', 'Git'), ('python3', 'Python')]
        self.assertEqual(self.drive('check', [' ', '\n'], '', options)[0], ('next', 'git\npython3'))
        self.assertEqual(self.drive('check', [' ', curses.KEY_UP, ' ', '\n'], '', options)[0], ('next', ''))

    def test_orange_green_theme_and_readable_highlight(self):
        screen = Screen(['\n'])
        with patch.dict(os.environ, {'NO_COLOR': ''}), patch.object(curses, 'curs_set'), patch.object(curses, 'has_colors', return_value=True), \
             patch.object(curses, 'start_color'), patch.object(curses, 'use_default_colors'), \
             patch.object(curses, 'COLORS', 256, create=True), patch.object(curses, 'init_pair') as pairs, \
             patch.object(curses, 'color_pair', return_value=0):
            self.ui.run(screen, 'yesno', 'Test', 'Question', '1', [])
        self.assertEqual([call.args for call in pairs.call_args_list], [(1, 208, -1), (2, 114, -1), (3, curses.COLOR_BLACK, 114), (4, 252, -1), (5, 252, 236)])

    def test_memory_chart_has_distinct_labels_values_and_aligned_columns(self):
        line = next(line for line in SCRIPT.read_text().splitlines() if "memory) title='Memory'" in line)
        prompt = ast.literal_eval(line.split('prompt=$', 1)[1][:-2])
        screen = Screen(['\n'])
        screen.getmaxyx = lambda: (24, 80)
        with patch.dict(os.environ, {'NO_COLOR': ''}), patch.object(curses, 'curs_set'), patch.object(curses, 'has_colors', return_value=True), \
             patch.object(curses, 'start_color'), patch.object(curses, 'use_default_colors'), \
             patch.object(curses, 'COLORS', 256, create=True), patch.object(curses, 'init_pair'), \
             patch.object(curses, 'color_pair', side_effect=lambda i: i * 16):
            result = self.ui.run(screen, 'input', 'Memory (required)', prompt, '1024', [])
        self.assertEqual(result, ('next', '1024'))
        values = [item for item in screen.positions if item[2].strip().isdigit() and len(item[2]) == 5]
        self.assertEqual(len(values), 16)
        self.assertEqual({int(item[2]) for item in values}, {i * 1024 for i in range(1, 17)})
        self.assertTrue(all(item[3] == (32 | curses.A_BOLD,) for item in values))
        labels = [item for item in screen.positions if item[2].endswith(' GiB = ')]
        self.assertEqual(len(labels), 16)
        self.assertTrue(all(item[3] == (64,) for item in labels))
        for y in {item[0] for item in values}:
            self.assertEqual([item[1] for item in values if item[0] == y], [14, 31, 48, 65])
        self.assertEqual(sum(item[2] == ' │ ' for item in screen.positions), 12)

    def test_arrow_only_input_navigation_and_cursor_editing(self):
        keys = [curses.KEY_LEFT, 'X', curses.KEY_DOWN, curses.KEY_LEFT, '\n']
        self.assertEqual(self.drive('input', keys, 'ab')[0], ('back', ''))
        keys = [curses.KEY_DOWN, curses.KEY_UP, curses.KEY_LEFT, 'X', '\n']
        self.assertEqual(self.drive('input', keys, 'ab')[0], ('next', 'aXb'))

    def test_arrow_only_list_and_button_navigation(self):
        options = [('vmbr0', ''), ('vmbr1', '')]
        self.assertEqual(self.drive('menu', [curses.KEY_DOWN, curses.KEY_DOWN, '\n'], '', options)[0], ('next', 'vmbr1'))
        keys = [curses.KEY_RIGHT, curses.KEY_UP, curses.KEY_DOWN, '\n']
        self.assertEqual(self.drive('menu', keys, '', options)[0], ('next', 'vmbr1'))
        keys = [curses.KEY_RIGHT, curses.KEY_LEFT, '\n']
        self.assertEqual(self.drive('check', keys, '', options)[0], ('back', ''))

    def test_none_excludes_packages_until_deselected(self):
        options = [('__all__', 'Select all / clear all'), ('__none__', 'None'), ('git', 'Git'), ('python3', 'Python')]
        keys = [curses.KEY_DOWN, ' ', curses.KEY_DOWN, ' ', '\n']
        self.assertEqual(self.drive('check', keys, '', options)[0], ('next', '__none__'))
        keys = [curses.KEY_DOWN, ' ', curses.KEY_UP, ' ', '\n']
        self.assertEqual(self.drive('check', keys, '', options)[0], ('next', 'git\npython3'))
        keys = [curses.KEY_DOWN, ' ', ' ', curses.KEY_DOWN, ' ', '\n']
        self.assertEqual(self.drive('check', keys, '', options)[0], ('next', 'git'))

    def test_centered_required_text_is_bold(self):
        screen = Screen(['\n'])
        with patch.object(curses, 'curs_set'), patch.object(curses, 'has_colors', return_value=False):
            self.ui.run(screen, 'menu', 'Bridge (required)', 'Choose a bridge', '', [('vmbr0', '')])
        for text in ('Choose a bridge', 'vmbr0'):
            matches = [entry for entry in screen.positions if entry[2] == text]
            self.assertTrue(matches)
            for y, x, value, attrs in matches:
                self.assertEqual(x, (89 - len(value)) // 2)
                self.assertTrue(attrs[0] & curses.A_BOLD)

    def test_tab_reaches_every_button_in_both_directions(self):
        for kind, seed, options in [('input', 'kept', []), ('password', '', []), ('menu', 'git', [('git', '')]), ('check', 'git', [('git', '')])]:
            with self.subTest(kind=kind):
                self.assertEqual(self.drive(kind, ['\t', '\n'], seed, options)[0], ('back', ''))
                self.assertEqual(self.drive(kind, ['\t', '\t', '\t', '\n'], seed, options)[0], ('abort', ''))
                self.assertEqual(self.drive(kind, [curses.KEY_BTAB, curses.KEY_BTAB, curses.KEY_BTAB, '\n'], seed, options)[0], ('back', ''))

    def test_password_always_starts_empty_even_with_previous_value(self):
        result, drawn = self.drive('password', list('new-secret') + ['\n'], 'previous-secret')
        self.assertEqual(result, ('next', 'new-secret'))
        self.assertNotIn('previous-secret', drawn)
        self.assertNotIn('***************', drawn)

    def test_text_field_has_no_full_width_inverse_bar(self):
        screen = Screen(['\n'])
        with patch.object(curses, 'curs_set'), patch.object(curses, 'has_colors', return_value=False):
            self.ui.run(screen, 'input', 'Test', 'Question', 'text', [])
        fields = [value for _, _, value, _ in screen.positions if value.startswith('[ ') and value.endswith(' ]')]
        self.assertTrue(fields)
        self.assertTrue(all(len(value) == 52 for value in fields))

    def test_review_uses_fixed_label_and_value_columns_and_scroll_count(self):
        prompt = 'CONTAINER\n  ID / name       204 / test\n  Tags            TEST\n\nRESOURCES\n  Root disk       local · 10 GiB'
        screen = Screen(['\n'])
        with patch.object(curses, 'curs_set'), patch.object(curses, 'has_colors', return_value=False):
            self.ui.run(screen, 'review', 'Review', prompt, '', [])
        labels = [x for _, x, value, _ in screen.positions if value in ('ID / name', 'Tags', 'Root disk')]
        values = [x for _, x, value, _ in screen.positions if value in ('204 / test', 'TEST', 'local · 10 GiB')]
        self.assertEqual(len(set(labels)), 1)
        self.assertEqual(len(set(values)), 1)
        self.assertGreater(values[0], labels[0])
        self.assertTrue(any('1-6/6' in value for value in screen.drawn))

    def test_empty_input_and_password_have_persistent_centered_boxes(self):
        for kind in ('input', 'password'):
            screen = Screen(['\t', '\t', '\n'])
            with patch.object(curses, 'curs_set'), patch.object(curses, 'has_colors', return_value=False):
                self.ui.run(screen, kind, 'Required', 'Enter a value', '', [])
            fields = [(x, value) for _, x, value, _ in screen.positions if value.startswith('[ ') and value.endswith(' ]')]
            self.assertGreaterEqual(len(fields), 3)
            self.assertEqual(set(fields), {((89 - 52) // 2, '[ ' + ' ' * 48 + ' ]')})

    def test_storage_requires_explicit_single_selection(self):
        options = [('local', ''), ('storage4tb', '')]
        keys = [curses.KEY_RIGHT, '\n', curses.KEY_DOWN, ' ', '\n']
        result, drawn = self.drive('select', keys, '', options)
        self.assertEqual(result, ('next', 'storage4tb'))
        self.assertIn('Select one option before continuing.', drawn)
        self.assertIn('( ) local', drawn)
        self.assertIn('(x) storage4tb', drawn)
        keys = [' ', curses.KEY_UP, curses.KEY_DOWN, ' ', '\n']
        self.assertEqual(self.drive('select', keys, '', options)[0], ('next', 'storage4tb'))
        for select_key in (' ', '\n'):
            self.assertEqual(self.drive('select', [select_key, '\n'], '', options)[0], ('next', 'local'))

    def test_storage_preserves_selection_on_return_and_allows_back(self):
        options = [('local', ''), ('storage4tb', '')]
        self.assertEqual(self.drive('select', [curses.KEY_RIGHT, '\n'], 'storage4tb', options)[0], ('next', 'storage4tb'))
        self.assertEqual(self.drive('select', ['\t', '\n'], '', options)[0], ('back', ''))

    def test_required_checkbox_blocks_empty_selection(self):
        screen = Screen([curses.KEY_RIGHT, '\n', ' ', curses.KEY_RIGHT, '\n'])
        with patch.object(curses, 'curs_set'), patch.object(curses, 'has_colors', return_value=False):
            result = self.ui.run(screen, 'check', 'Devices (required)', 'Choose devices', '', [('gpu0', '')])
        self.assertEqual(result, ('next', 'gpu0'))
        self.assertIn('Select at least one option before continuing.', screen.drawn)

    def test_select_all_focuses_next_but_individual_choices_do_not(self):
        options = [('__all__', 'Select all / clear all'), ('git', 'Git'), ('python3', 'Python')]
        self.assertEqual(self.drive('check', [' ', '\n'], '', options)[0], ('next', 'git\npython3'))
        keys = [curses.KEY_DOWN, ' ', curses.KEY_DOWN, ' ', '\n']
        self.assertEqual(self.drive('check', keys, '', options)[0], ('next', 'git\npython3'))
        keys = [' ', curses.KEY_UP, ' ', curses.KEY_DOWN, ' ', '\n']
        self.assertEqual(self.drive('check', keys, '', options)[0], ('next', 'git'))

    def test_no_default_for_optional_features(self):
        self.assertEqual(self.drive('yesno', ['\n'], '0')[0], ('next', '0'))


if __name__ == '__main__': unittest.main()
