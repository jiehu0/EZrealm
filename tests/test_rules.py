"""Run with Python 3.11+: python3 -m unittest discover -s tests -v.

Only temporary configs and a shell function replacing systemctl are used.
No root access, installation, or changes to the host service are required.
"""
import os
from pathlib import Path
import shlex
import stat
import subprocess
import tempfile
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[1]
CONFIG = '''[network]
no_tcp = false
use_udp = true

[[endpoints]]
# 备注: first: 中文
remote = 'old.example.com:8080' # keep remote comment

# unrelated comment
listen = "127.0.0.1:18001" # keep listen comment
through = "192.0.2.1:0"

[[endpoints]] # second
listen = "127.0.0.1:18002"
# 备注: second
remote = "192.0.2.2:9000"

[log]
level = "info"
'''

SERVICE_STUB = r'''
sleep() { :; }
lsof() {
    if [[ "$SERVICE_MODE" == listener-once ]]; then
        [[ $(grep -c '^restart ' "$CALLS") -gt 1 ]]
    else
        return 0
    fi
}
systemctl() {
    printf '%s\n' "$*" >> "$CALLS"
    local n
    n=$(grep -c '^restart ' "$CALLS")
    [[ "$1" != show ]] || { printf '12345\n'; return 0; }
    case "$SERVICE_MODE:$1" in
        fail-once:restart) [[ "$n" -gt 1 ]] ;;
        fail-all:restart) return 1 ;;
        inactive-once:is-active) [[ "$n" -gt 1 ]] ;;
        *) return 0 ;;
    esac
}
'''


class RuleCases:
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ezrealm test ")
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.config = self.folder / "config.toml"
        self.config.write_text(CONFIG)
        self.config.chmod(0o640)
        self.calls = self.folder / "service-calls"

    def run_bash(self, command, inputs="", mode="success", setup=""):
        env = dict(os.environ, CONFIG_FILE=str(self.config), CALLS=str(self.calls),
                   SERVICE_MODE=mode, LOG_FILE=str(self.folder / "manager.log"))
        body = f'source {shlex.quote(str(ROOT / self.script))}\n'
        # The script intentionally uses production defaults. Override after sourcing.
        body += f'CONFIG_FILE={shlex.quote(str(self.config))}\n'
        body += f'LOG_FILE={shlex.quote(str(self.folder / "manager.log"))}\n'
        body += SERVICE_STUB + "\n" + setup + "\n" + command
        return subprocess.run(["bash", "-c", body], input=inputs, text=True,
                              capture_output=True, env=env, timeout=10)

    def edit(self, fields=("", "", "", "", ""), selection="1", confirm="y", **kwargs):
        return self.run_bash("edit_rule", "\n".join([selection, *fields, confirm]) + "\n", **kwargs)

    def data(self):
        return tomllib.loads(self.config.read_text())

    def assert_no_restart(self):
        self.assertFalse(self.calls.exists(), self.calls.read_text() if self.calls.exists() else "")
        self.assertEqual([], list(self.folder.glob("*.tmp.*")))
        self.assertEqual([], list(self.folder.glob("*.snapshot.*")))

    def test_display_handles_order_comments_and_colons(self):
        result = self.run_bash("show_rules")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("first: 中文", result.stdout)
        self.assertIn("127.0.0.1:18001", result.stdout)
        self.assertIn("old.example.com:8080", result.stdout)
        self.assert_no_restart()

    def test_edit_only_selected_rule_and_preserve_metadata(self):
        old = self.data()
        before = self.config.stat()
        result = self.edit(("0.0.0.0", "19001", "new.example.com", "443", r'新: "备注" \n & $HOME'))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        data = self.data()
        self.assertEqual(data["endpoints"][0]["listen"], "0.0.0.0:19001")
        self.assertEqual(data["endpoints"][0]["remote"], "new.example.com:443")
        self.assertEqual(data["endpoints"][0]["through"], old["endpoints"][0]["through"])
        self.assertEqual(data["endpoints"][1], old["endpoints"][1])
        self.assertEqual(data["network"], old["network"])
        self.assertEqual(data["log"], old["log"])
        text = self.config.read_text()
        self.assertIn('# keep listen comment', text)
        self.assertIn('# keep remote comment', text)
        self.assertIn(r'# 备注: 新: "备注" \n & $HOME', text)
        after = self.config.stat()
        self.assertEqual(stat.S_IMODE(after.st_mode), stat.S_IMODE(before.st_mode))
        self.assertEqual((after.st_uid, after.st_gid), (before.st_uid, before.st_gid))
        backups = list(self.folder.glob("*.bak.*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), CONFIG)

    def test_edit_first_middle_and_last_rule(self):
        text = CONFIG.replace('[log]', '[[endpoints]]\nlisten = "127.0.0.1:18003"\nremote = "192.0.2.3:80"\n\n[log]')
        for selection in ("1", "2", "3"):
            with self.subTest(selection=selection):
                self.config.write_text(text)
                before = self.data()
                result = self.edit(("", "", "new.example.com", "", ""), selection=selection)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                after = self.data()
                for i in range(3):
                    if i == int(selection) - 1:
                        self.assertTrue(after["endpoints"][i]["remote"].startswith("new.example.com:"))
                    else:
                        self.assertEqual(before["endpoints"][i], after["endpoints"][i])

    def test_keep_all_values_does_not_write_or_restart(self):
        result = self.edit()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.config.read_text(), CONFIG)
        self.assertIn("没有变化", result.stdout)
        self.assert_no_restart()

    def test_cancel_at_every_prompt_and_final_confirmation(self):
        for step in range(7):
            with self.subTest(step=step):
                values = ["1", "", "19001", "", "", "", "y"]
                values[step] = "q" if step < 6 else "n"
                result = self.run_bash("edit_rule", "\n".join(values[:step+1]) + "\n")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.config.read_text(), CONFIG)
                self.assert_no_restart()

    def test_eof_does_not_write(self):
        self.edit(("", "19001", "", "", ""), confirm="")
        self.assertEqual(self.config.read_text(), CONFIG)
        self.assert_no_restart()

    def test_clear_remark(self):
        result = self.edit(("", "", "", "", "-"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("first: 中文", self.config.read_text())
        self.assertIn("# 备注: second", self.config.read_text())

    def test_invalid_selection(self):
        for selection in ("0", "3", "-1", "abc", "99999999999999999999", ""):
            with self.subTest(selection=selection):
                self.edit(selection=selection)
                self.assertEqual(self.config.read_text(), CONFIG)
                self.assert_no_restart()

    def test_invalid_ports_and_addresses(self):
        for fields in (("", "0", "", "", ""), ("", "65536", "", "", ""),
                       ("", "80x", "", "", ""), ("", "", "999.1.1.1", "", ""),
                       ("", "", "a..example.com", "", ""), ("bad-host", "", "", "", ""),
                       ("", "", "::1::2", "", ""), ("", "", "new\"host", "", "")):
            with self.subTest(fields=fields):
                result = self.edit(fields)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.config.read_text(), CONFIG)
                self.assert_no_restart()

    def test_listen_conflict(self):
        for host in ("127.0.0.1", "0.0.0.0", "::"):
            with self.subTest(host=host):
                result = self.edit((host, "18002", "", "", ""))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("冲突", result.stdout)
                self.assertEqual(self.config.read_text(), CONFIG)
                self.assert_no_restart()

    def test_ipv6_addresses(self):
        result = self.edit(("::1", "19001", "[2001:db8::2]", "443", "IPv6"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.data()["endpoints"][0]["listen"], "[::1]:19001")
        self.assertEqual(self.data()["endpoints"][0]["remote"], "[2001:db8::2]:443")

    def test_address_validation(self):
        valid = ["[::]:80", "[::1]:443", "[2001:db8::1]:80", "[::ffff:192.0.2.1]:80",
                 "[1:2:3:4:5:6:7:8]:80", "localhost:65535", "example.com.:80", "127.0.0.1:00080"]
        invalid = ["[:::]:80", "[1:2:3]:80", "[1:2:3:4:5:6:7:8::]:80", "[gg::1]:80",
                   "[::ffff:999.0.0.1]:80", "127.0.0.1:0", "127.0.0.1:65536", "-bad.example:80",
                   "[1::2::3]:80", "2001:db8::1:80", "a..:80", "[:1::2]:80", "[1::2:]:80", "127.001.0.1:80"]
        for address in valid + invalid:
            with self.subTest(address=address):
                result = self.run_bash("split_address " + shlex.quote(address))
                self.assertEqual(result.returncode == 0, address in valid, result.stderr)

    def test_restart_failure_restores_original_and_retries_service(self):
        for mode in ("fail-once", "inactive-once", "listener-once", "fail-all"):
            with self.subTest(mode=mode):
                self.calls.unlink(missing_ok=True)
                result = self.edit(("", "19001", "", "", ""), mode=mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.config.read_text(), CONFIG)
                self.assertEqual(self.calls.read_text().count("restart realm.service"), 2)
                self.assertIn("服务恢复失败" if mode == "fail-all" else "已恢复原配置和服务", result.stdout)

    def test_concurrent_external_change_is_not_overwritten(self):
        setup = r'''read() {
            builtin read "$@"
            local status=$?
            if [[ "$answer" == y ]]; then printf '# external change\n' >> "$CONFIG_FILE"; fi
            return "$status"
        }'''
        result = self.edit(("", "19001", "", "", ""), setup=setup)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.config.read_text(), CONFIG + "# external change\n")
        self.assert_no_restart()

    def test_unsupported_address_is_not_changed(self):
        text = CONFIG.replace("remote = 'old.example.com:8080'", 'remote = ["192.0.2.1:80"]')
        self.config.write_text(text)
        result = self.edit(("", "19001", "", "", ""))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.config.read_text(), text)
        self.assert_no_restart()

    def test_missing_and_duplicate_fields_are_not_edited(self):
        for text in (CONFIG.replace('listen = "127.0.0.1:18001" # keep listen comment\n', ''),
                     CONFIG.replace('listen = "127.0.0.1:18001"', 'listen = "127.0.0.1:18001"\nlisten = "127.0.0.1:18003"')):
            with self.subTest(text=text):
                self.config.write_text(text)
                result = self.edit(("", "19001", "", "", ""))
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.config.read_text(), text)
                self.assert_no_restart()

    def test_file_replacement_failure_keeps_original(self):
        result = self.edit(("", "19001", "", "", ""), setup='mv() { return 1; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.config.read_text(), CONFIG)
        self.assert_no_restart()
        self.assertEqual(list(self.folder.glob('*.bak.*'))[0].read_text(), CONFIG)

    def test_protocol_flags_use_endpoint_overrides(self):
        self.config.write_text(CONFIG.replace('[log]', '[endpoints.network]\nno_tcp = true\nuse_udp = false\n[log]'))
        result = self.run_bash('rule_protocols 1; rule_protocols 2')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '0 1\n1 0\n')

    def test_udp_listener_is_checked_even_when_tcp_is_listening(self):
        setup = r'''lsof() {
            case " $* " in *" UDP@"*) return 1 ;; *) return 0 ;; esac
        }'''
        result = self.edit(("", "19001", "", "", ""), setup=setup)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('UDP 端口未由 Realm 监听', result.stdout)
        self.assertEqual(self.config.read_text(), CONFIG)

    def test_nested_tables_are_preserved_during_edit(self):
        text = CONFIG.replace('[[endpoints]] # second', '[endpoints.network]\nremote = "custom"\nlisten = "custom"\n\n[[endpoints]] # second')
        self.config.write_text(text)
        old = self.data()
        result = self.edit(("", "19001", "", "", ""))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.data()["endpoints"][0]["network"], old["endpoints"][0]["network"])

    def test_delete_first_and_last_preserves_other_sections(self):
        for index in (1, 2):
            with self.subTest(index=index):
                self.config.write_text(CONFIG)
                old = self.data()
                result = self.run_bash("delete_rule", f"{index}\n")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.data()["endpoints"], [old["endpoints"][2-index]])
                self.assertEqual(self.data()["log"], old["log"])
                self.assertEqual(self.data()["network"], old["network"])

    def test_delete_only_rule_and_nested_tables(self):
        text = '[network]\nuse_udp = true\n[[endpoints]]\nlisten = "127.0.0.1:80"\nremote = "127.0.0.1:81"\n[endpoints.network]\nuse_udp = false\n[log]\nlevel = "info"\n'
        self.config.write_text(text)
        result = self.run_bash("delete_rule", "1\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("endpoints", self.data())
        self.assertEqual(self.data()["log"]["level"], "info")
        self.assertEqual(self.calls.read_text(), 'stop realm.service\n')

    def test_add_and_add_failure_rollback(self):
        for mode in ("success", "fail-once"):
            with self.subTest(mode=mode):
                self.config.write_text(CONFIG)
                self.calls.unlink(missing_ok=True)
                result = self.run_bash("add_rule", "19003\n::1\n8080\nnew: 中文\n2\nn\n", mode=mode)
                if mode == "success":
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(self.data()["endpoints"][2]["remote"], "[::1]:8080")
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(self.config.read_text(), CONFIG)

    def test_missing_or_empty_config(self):
        for missing in (False, True):
            with self.subTest(missing=missing):
                self.config.unlink(missing_ok=True)
                if not missing:
                    self.config.write_text('[network]\nuse_udp = true\n')
                result = self.edit()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("没有发现", result.stdout)
                self.assert_no_restart()


for name, script in (("MainRules", "realm.sh"), ("ChinaRules", "CN/realm.sh"), ("PreviewRules", "test/realm.sh")):
    globals()[name] = type(name, (RuleCases, unittest.TestCase), {"script": script})


if __name__ == "__main__":
    unittest.main()
