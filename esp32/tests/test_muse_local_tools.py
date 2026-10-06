"""Production countdown and wake alarm, including time spent with display paused."""
import ctypes as c
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Timer(c.Structure):
    _fields_ = [("remaining_ms", c.c_uint32), ("started_ms", c.c_uint32),
                ("running", c.c_bool), ("finished", c.c_bool)]


class Recipe(c.Structure):
    _fields_ = [("name", c.c_char_p), ("instructions", c.c_char_p), ("seconds", c.c_uint32)]


class LocalToolsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        lib = Path(cls.tmp.name) / "tools.so"
        subprocess.run([*shlex.split(os.environ.get("CC", "cc")), "-std=c11",
                        "-Wall", "-Wextra", "-Werror", "-shared", "-fPIC",
                        str(ROOT / "components/muse/muse_local_tools.c"), "-o", str(lib)],
                       check=True, capture_output=True)
        cls.lib = c.CDLL(str(lib))
        cls.lib.muse_timer_start.argtypes = [c.POINTER(Timer), c.c_uint32, c.c_uint32]
        cls.lib.muse_timer_start.restype = c.c_bool
        cls.lib.muse_timer_update.argtypes = [c.POINTER(Timer), c.c_uint32]
        cls.lib.muse_timer_update.restype = c.c_bool
        for name in ("pause", "resume"):
            getattr(cls.lib, "muse_timer_" + name).argtypes = [c.POINTER(Timer), c.c_uint32]
        cls.lib.muse_tools_alarm_set.argtypes = [c.c_bool, c.c_uint32]
        cls.lib.muse_tools_alarm_take.argtypes = [c.c_uint32]
        cls.lib.muse_tools_alarm_take.restype = c.c_bool
        cls.lib.muse_recipe_count.restype = c.c_size_t
        cls.lib.muse_recipe_get.argtypes = [c.c_size_t]
        cls.lib.muse_recipe_get.restype = c.POINTER(Recipe)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_countdown_catches_up_after_display_stops(self):
        timer = Timer()
        self.assertTrue(self.lib.muse_timer_start(c.byref(timer), 180000, 100))
        self.assertTrue(self.lib.muse_timer_update(c.byref(timer), 200100))
        self.assertEqual(timer.remaining_ms, 0)
        self.assertTrue(timer.finished)
        self.assertFalse(timer.running)
        self.assertFalse(self.lib.muse_timer_update(c.byref(timer), 300100))

    def test_pause_resume_excludes_paused_time(self):
        timer = Timer()
        self.lib.muse_timer_start(c.byref(timer), 60000, 100)
        self.lib.muse_timer_pause(c.byref(timer), 10100)
        self.assertEqual(timer.remaining_ms, 50000)
        self.lib.muse_timer_update(c.byref(timer), 200100)
        self.assertEqual(timer.remaining_ms, 50000)
        self.lib.muse_timer_resume(c.byref(timer), 200100)
        self.lib.muse_timer_update(c.byref(timer), 210100)
        self.assertEqual(timer.remaining_ms, 40000)

    def test_countdown_handles_clock_wrap(self):
        timer = Timer()
        self.lib.muse_timer_start(c.byref(timer), 1000, 0xFFFFFFF0)
        self.lib.muse_timer_update(c.byref(timer), 20)
        self.assertEqual(timer.remaining_ms, 964)
        self.assertTrue(self.lib.muse_timer_update(c.byref(timer), 984))

    def test_invalid_duration_does_not_replace_running_timer(self):
        timer = Timer()
        self.lib.muse_timer_start(c.byref(timer), 1000, 0)
        for duration in (0, 86400001, 0xFFFFFFFF):
            self.assertFalse(self.lib.muse_timer_start(c.byref(timer), duration, 100))
            self.assertEqual(timer.remaining_ms, 1000)

    def test_alarm_fires_once_and_cancel_stays_cancelled(self):
        self.lib.muse_tools_alarm_set(True, 1000)
        self.assertFalse(self.lib.muse_tools_alarm_take(999))
        self.assertTrue(self.lib.muse_tools_alarm_take(1000))
        self.assertFalse(self.lib.muse_tools_alarm_take(1001))
        self.lib.muse_tools_alarm_set(True, 2000)
        self.lib.muse_tools_alarm_set(False, 0)
        self.assertFalse(self.lib.muse_tools_alarm_take(3000))

    def test_alarm_wrap_and_rearm(self):
        self.lib.muse_tools_alarm_set(True, 20)
        self.assertFalse(self.lib.muse_tools_alarm_take(0xFFFFFFF0))
        self.lib.muse_tools_alarm_set(True, 2000)
        self.assertFalse(self.lib.muse_tools_alarm_take(20))
        self.assertTrue(self.lib.muse_tools_alarm_take(2000))
        self.lib.muse_tools_alarm_set(True, 0)
        self.assertFalse(self.lib.muse_tools_alarm_take(0))
        self.assertTrue(self.lib.muse_tools_alarm_take(1))

    def test_recipes_are_available_without_network_or_heap(self):
        self.assertEqual(self.lib.muse_recipe_count(), 2)
        recipe = self.lib.muse_recipe_get(0).contents
        self.assertEqual(recipe.seconds, 180)
        self.assertIn(b"250g", recipe.instructions)
        self.assertFalse(self.lib.muse_recipe_get(2))
