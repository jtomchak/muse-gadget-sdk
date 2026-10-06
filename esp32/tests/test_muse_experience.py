"""Execute the production experience policy on the host, without ESP-IDF."""
import ctypes
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ExperienceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        lib = Path(cls.tmp.name) / "experience.so"
        subprocess.run([
            *shlex.split(os.environ.get("CC", "cc")), "-std=c11", "-Wall",
            "-Wextra", "-Werror", "-shared", "-fPIC",
            str(ROOT / "components/muse/muse_experience.c"), "-o", str(lib),
        ], check=True, capture_output=True)
        cls.policy = ctypes.CDLL(str(lib))
        cls.policy.muse_experience_press.argtypes = [ctypes.c_bool, ctypes.c_uint32]
        cls.policy.muse_experience_preparing.argtypes = [ctypes.c_uint32]
        cls.policy.muse_experience_preparing.restype = ctypes.c_bool
        cls.policy.muse_experience_avatar_ms.argtypes = [ctypes.c_bool] * 3 + [ctypes.c_uint32]
        cls.policy.muse_experience_avatar_ms.restype = ctypes.c_uint32

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_feedback_is_immediate_and_clears_on_release(self):
        self.policy.muse_experience_press(True, 100)
        self.assertTrue(self.policy.muse_experience_preparing(100))
        self.policy.muse_experience_press(False, 120)
        self.assertFalse(self.policy.muse_experience_preparing(120))

    def test_rejected_or_stuck_press_expires(self):
        self.policy.muse_experience_press(True, 100)
        self.assertTrue(self.policy.muse_experience_preparing(1099))
        self.assertFalse(self.policy.muse_experience_preparing(1100))

    def test_feedback_across_clock_wrap(self):
        self.policy.muse_experience_press(True, 0xFFFFFFF0)
        self.assertTrue(self.policy.muse_experience_preparing(20))
        self.assertFalse(self.policy.muse_experience_preparing(984))

    def test_audio_reduces_avatar_work_without_speeding_up_slower_boards(self):
        self.assertEqual(self.policy.muse_experience_avatar_ms(True, False, False, 40), 120)
        self.assertEqual(self.policy.muse_experience_avatar_ms(False, False, False, 40), 40)
        self.assertEqual(self.policy.muse_experience_avatar_ms(True, False, False, 200), 200)

    def test_idle_battery_is_slower_than_desk_and_active_reactions(self):
        self.assertEqual(self.policy.muse_experience_avatar_ms(False, True, False, 40), 80)
        self.assertEqual(self.policy.muse_experience_avatar_ms(False, True, True, 40), 200)
        self.assertEqual(self.policy.muse_experience_avatar_ms(False, False, True, 40), 40)
