"""Settings store: atomic replacement, shared locking, recovery from damaged files."""
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

import orbit_settings as settings


class SettingsStoreTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.path = Path(self.folder.name) / "Orbit" / "settings.json"

    def leftovers(self):
        return sorted(item.name for item in self.path.parent.iterdir() if item.name != self.path.name)

    def test_missing_file_reads_defaults_without_creating_anything(self):
        store = settings.SettingsStore(self.path)
        self.assertEqual(store.get("alerts", {"pcToasts": True}), {"pcToasts": True})
        self.assertIsNone(store.get("deck"))
        self.assertEqual(store.snapshot(), {})
        self.assertFalse(self.path.parent.exists())

    def test_update_merges_replace_overwrites_and_values_round_trip(self):
        store = settings.SettingsStore(self.path)
        self.assertEqual(store.update("alerts", {"pcToasts": False}), {"pcToasts": False})
        self.assertEqual(store.update("alerts", {"temperature": {"cpu": 90}}), {"pcToasts": False, "temperature": {"cpu": 90}})
        self.assertEqual(store.replace("deck", {"buttons": [1, 2], "updatedAt": "2026-10-23T18:00:00Z"}),
                         {"buttons": [1, 2], "updatedAt": "2026-10-23T18:00:00Z"})
        self.assertEqual(store.replace("energy", 1.5), 1.5)
        on_disk = json.loads(self.path.read_text(encoding="utf-8"))
        self.assertEqual(on_disk, {"alerts": {"pcToasts": False, "temperature": {"cpu": 90}},
                                   "deck": {"buttons": [1, 2], "updatedAt": "2026-10-23T18:00:00Z"}, "energy": 1.5})
        # A fresh store (another feature, or after a restart) reads the same values.
        self.assertEqual(settings.SettingsStore(self.path).get("alerts")["temperature"], {"cpu": 90})
        self.assertEqual(self.leftovers(), [])

    def test_update_of_a_non_dict_section_starts_a_new_dict(self):
        store = settings.SettingsStore(self.path)
        store.replace("display", "legacy")
        self.assertEqual(store.update("display", {"enabled": True}), {"enabled": True})

    def test_returned_values_are_private_copies(self):
        store = settings.SettingsStore(self.path)
        store.replace("deck", {"buttons": [{"id": "a"}]})
        value = store.get("deck")
        value["buttons"].append({"id": "b"})
        snapshot = store.snapshot()
        snapshot["deck"]["buttons"].clear()
        default = {"nested": []}
        got = store.get("missing", default)
        got["nested"].append(1)
        self.assertEqual(store.get("deck"), {"buttons": [{"id": "a"}]})
        self.assertEqual(default, {"nested": []})

    def test_invalid_input_is_rejected_before_anything_is_written(self):
        store = settings.SettingsStore(self.path)
        store.update("alerts", {"pcToasts": True})
        before = self.path.read_bytes()
        for section in ("", "has space", "../escape", 5, None, "x" * 65):
            with self.subTest(section=section), self.assertRaises(ValueError):
                store.update(section, {"a": 1})
        with self.assertRaises(TypeError):
            store.update("alerts", ["not", "a", "dict"])
        with self.assertRaises(ValueError):
            store.update("alerts", {"bad": float("nan")})
        with self.assertRaises(TypeError):
            store.replace("alerts", {"object": object()})
        with patch.object(settings, "MAX_SETTINGS_BYTES", 64), self.assertRaises(ValueError):
            store.replace("big", "x" * 100)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(store.get("alerts"), {"pcToasts": True})
        self.assertEqual(self.leftovers(), [])

    def test_failed_replace_keeps_the_old_file_and_cleans_the_temporary_file(self):
        store = settings.SettingsStore(self.path)
        store.update("alerts", {"pcToasts": True})
        before = self.path.read_bytes()
        with patch.object(settings.os, "replace", side_effect=OSError("disk vanished")), self.assertRaises(OSError):
            store.update("alerts", {"pcToasts": False})
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(self.leftovers(), [])
        # The cache was not changed by the failed write either.
        self.assertEqual(store.get("alerts"), {"pcToasts": True})

    def test_failed_fsync_never_touches_the_settings_file(self):
        store = settings.SettingsStore(self.path)
        store.update("alerts", {"pcToasts": True})
        before = self.path.read_bytes()
        with patch.object(settings.os, "fsync", side_effect=OSError("I/O error")), self.assertRaises(OSError):
            store.update("alerts", {"pcToasts": False})
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(self.leftovers(), [])

    def test_sharing_violation_is_retried(self):
        store = settings.SettingsStore(self.path)
        store.update("alerts", {"pcToasts": True})
        real_replace = os.replace
        attempts = []

        def flaky(source, target):
            attempts.append(source)
            if len(attempts) < 3:
                raise PermissionError("in use by antivirus")
            return real_replace(source, target)
        with patch.object(settings.os, "replace", flaky), patch.object(settings.time, "sleep"):
            store.update("alerts", {"pcToasts": False})
        self.assertEqual(len(attempts), 3)
        self.assertEqual(json.loads(self.path.read_text())["alerts"], {"pcToasts": False})
        with patch.object(settings.os, "replace", side_effect=PermissionError("locked")), \
             patch.object(settings.time, "sleep"), self.assertRaises(PermissionError):
            store.update("alerts", {"pcToasts": True})
        self.assertEqual(self.leftovers(), [])

    @unittest.skipIf(os.name == "nt", "POSIX permission bits")
    def test_files_are_private(self):
        store = settings.SettingsStore(self.path.with_name(settings.SECRETS_FILE_NAME))
        store.replace("channel", {"secret": "s3cret"})
        self.assertEqual(store.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.path.parent.stat().st_mode & 0o777, 0o700)

    def test_damaged_file_is_set_aside_and_defaults_are_used(self):
        self.path.parent.mkdir(parents=True)
        for damaged in (b"{not json", b"[1, 2, 3]", b"\xff\xfe\x00garbage", b'"text"'):
            with self.subTest(content=damaged):
                self.path.write_bytes(damaged)
                store = settings.SettingsStore(self.path)
                with self.assertLogs("orbit.settings", "WARNING") as logged:
                    self.assertEqual(store.get("alerts", "default"), "default")
                self.assertIn("settings.json.corrupt", logged.output[0])
                self.assertEqual(self.path.with_name("settings.json.corrupt").read_bytes(), damaged)
                self.assertFalse(self.path.exists())
                store.update("alerts", {"pcToasts": False})
                self.assertEqual(json.loads(self.path.read_text()), {"alerts": {"pcToasts": False}})
                self.path.unlink()

    def test_utf8_bom_from_notepad_is_accepted(self):
        self.path.parent.mkdir(parents=True)
        self.path.write_bytes("﻿".encode("utf-8") + json.dumps({"alerts": {"pcToasts": False}}).encode())
        self.assertEqual(settings.SettingsStore(self.path).get("alerts"), {"pcToasts": False})

    def test_change_from_another_process_is_noticed_before_the_next_update(self):
        store = settings.SettingsStore(self.path)
        store.update("alerts", {"pcToasts": True})
        # Another process (the boot-time instance) rewrites the file the same atomic way.
        replacement = self.path.with_name("other.tmp")
        replacement.write_text(json.dumps({"alerts": {"pcToasts": True}, "energy": {"baseWatts": 80}}))
        os.replace(replacement, self.path)
        self.assertEqual(store.get("energy"), {"baseWatts": 80})
        store.update("alerts", {"pcToasts": False})
        self.assertEqual(json.loads(self.path.read_text()),
                         {"alerts": {"pcToasts": False}, "energy": {"baseWatts": 80}})

    def test_unreadable_file_keeps_last_good_values_for_reads_and_refuses_writes(self):
        store = settings.SettingsStore(self.path)
        store.update("alerts", {"pcToasts": False})
        replacement = self.path.with_name("other.tmp")
        replacement.write_text(json.dumps({"alerts": {"pcToasts": True}, "x": 1}))
        os.replace(replacement, self.path)
        with patch.object(Path, "read_bytes", side_effect=PermissionError("locked")), \
             patch.object(settings.time, "sleep"):
            with self.assertLogs("orbit.settings", "WARNING"):
                self.assertEqual(store.get("alerts"), {"pcToasts": False})
            with self.assertRaises(PermissionError):
                store.update("alerts", {"pcToasts": True})
        self.assertEqual(json.loads(self.path.read_text()), {"alerts": {"pcToasts": True}, "x": 1})

    def test_remove_section(self):
        store = settings.SettingsStore(self.path)
        store.update("alerts", {"pcToasts": False})
        store.update("deck", {"buttons": []})
        self.assertTrue(store.remove("alerts"))
        self.assertFalse(store.remove("alerts"))
        self.assertEqual(json.loads(self.path.read_text()), {"deck": {"buttons": []}})

    def test_concurrent_updates_from_many_threads_and_stores_lose_nothing(self):
        stores = [settings.SettingsStore(self.path) for _ in range(4)]
        threads_count, rounds = 8, 25
        errors = []
        start = threading.Barrier(threads_count)

        def worker(index):
            store = stores[index % len(stores)]
            try:
                start.wait()
                for round_number in range(rounds):
                    store.update("alerts", {f"worker{index}": round_number})
                    store.modify("energy", lambda value: {"count": (value or {}).get("count", 0) + 1}, default={})
            except Exception as error:  # pragma: no cover - reported below
                errors.append(error)
        threads = [threading.Thread(target=worker, args=(index,)) for index in range(threads_count)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(30)
        self.assertEqual(errors, [])
        final = json.loads(self.path.read_text())
        self.assertEqual(final["alerts"], {f"worker{index}": rounds - 1 for index in range(threads_count)})
        self.assertEqual(final["energy"], {"count": threads_count * rounds})
        self.assertEqual(settings.SettingsStore(self.path).get("energy"), {"count": threads_count * rounds})
        self.assertEqual(self.leftovers(), [])

    def test_readers_never_see_a_half_written_file(self):
        store = settings.SettingsStore(self.path)
        store.replace("deck", {"buttons": ["x" * 200] * 50})
        stop = threading.Event()
        problems = []

        def reader():
            while not stop.is_set():
                try:
                    json.loads(self.path.read_bytes())
                except FileNotFoundError:
                    problems.append("missing")
                except ValueError as error:
                    problems.append(error)

        thread = threading.Thread(target=reader)
        thread.start()
        try:
            for index in range(60):
                store.replace("deck", {"buttons": [str(index) * 200] * (50 + index)})
        finally:
            stop.set()
            thread.join(10)
        self.assertEqual(problems, [])

    def test_shared_store_defaults_to_the_data_directory_and_can_be_swapped(self):
        settings.set_shared_store(None)
        self.addCleanup(settings.set_shared_store, None)
        with patch.dict(os.environ, {"LOCALAPPDATA": self.folder.name}):
            shared = settings.shared_store()
            self.assertIs(settings.shared_store(), shared)
            self.assertEqual(shared.path, Path(self.folder.name) / "Orbit" / "settings.json")
            self.assertEqual(settings.default_secrets_path(), Path(self.folder.name) / "Orbit" / "push-secrets.json")
        custom = settings.SettingsStore(self.path)
        settings.set_shared_store(custom)
        self.assertIs(settings.shared_store(), custom)


if __name__ == "__main__":
    unittest.main()
