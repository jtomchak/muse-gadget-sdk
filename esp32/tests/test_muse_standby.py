"""Run production standby timing and QMI tap setup with a fake clock/I2C bus."""
import ctypes
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class StandbyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        p = Path(cls.tmp.name)
        (p / "sdkconfig.h").write_text("#define CONFIG_MUSE_BOARD_SIMULATOR 1\n")
        (p / "esp_timer.h").write_text("#include <stdint.h>\nint64_t esp_timer_get_time(void);\n")
        (p / "clock.c").write_text("#include <stdint.h>\nint64_t fake_us;\nint64_t esp_timer_get_time(void) { return fake_us; }\n")
        lib = p / "standby.so"
        subprocess.run([*shlex.split(os.environ.get("CC", "cc")), "-std=c11",
            "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra", "-Werror", "-shared", "-fPIC",
            "-I" + str(p), str(ROOT / "components/muse/muse_standby.c"),
            str(ROOT / "components/muse/muse_tap.c"), str(p / "clock.c"), "-o", str(lib)], check=True)
        cls.lib = ctypes.CDLL(str(lib))
        cls.lib.muse_standby_can_pause.argtypes = [ctypes.c_uint32]
        cls.lib.muse_standby_can_pause.restype = ctypes.c_bool
        cls.lib.muse_standby_rendered.argtypes = [ctypes.c_uint32]
        cls.lib.muse_standby_enabled.restype = ctypes.c_bool
        cls.lib.muse_standby_tap_enabled.restype = ctypes.c_bool
        cls.lib.muse_tap_configure.restype = ctypes.c_bool
        cls.us = ctypes.c_int64.in_dll(cls.lib, "fake_us")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_clock_changes_at_minute_boundary(self):
        text, minute = ctypes.create_string_buffer(6), ctypes.c_int()
        self.us.value = 59_999_000
        self.lib.muse_standby_clock(text, ctypes.byref(minute))
        before = text.value
        self.us.value = 60_000_000
        self.lib.muse_standby_clock(text, ctypes.byref(minute))
        self.assertNotEqual(text.value, before)

    def test_pause_waits_for_flush_and_resumes_at_minute_boundary(self):
        self.us.value = 59_000_000
        self.lib.muse_standby_rendered(59000)
        self.assertFalse(self.lib.muse_standby_can_pause(59249))
        self.assertTrue(self.lib.muse_standby_can_pause(59250))
        self.us.value = 60_000_000
        self.assertFalse(self.lib.muse_standby_can_pause(60000))
        self.lib.muse_standby_rendered(60000)
        self.assertTrue(self.lib.muse_standby_can_pause(60250))
        self.lib.muse_standby_exit()
        self.assertFalse(self.lib.muse_standby_can_pause(60300))

    def test_pause_timer_handles_uptime_wrap(self):
        self.us.value = 1_000_000
        self.lib.muse_standby_rendered(0xfffffff0)
        self.assertFalse(self.lib.muse_standby_can_pause(0x10))
        self.assertTrue(self.lib.muse_standby_can_pause(0x100))
        self.lib.muse_standby_exit()

    def test_preferences_and_shortcut_cycle(self):
        before = self.lib.muse_standby_enabled()
        self.lib.muse_standby_toggle()
        self.assertEqual(self.lib.muse_standby_enabled(), not before)
        self.lib.muse_standby_toggle()
        self.assertFalse(self.lib.muse_standby_tap_enabled())
        self.lib.muse_standby_toggle_tap()
        self.assertTrue(self.lib.muse_standby_tap_enabled())
        self.lib.muse_standby_toggle_tap()
        for expected in (1, 2, 0):
            self.lib.muse_standby_next_shortcut()
            self.assertEqual(self.lib.muse_standby_shortcut(), expected)

    def configure(self, fail_at=None, stuck=False, id_value=5):
        read_t = ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_uint8, ctypes.POINTER(ctypes.c_uint8))
        write_t = ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_uint8, ctypes.c_uint8)
        delay_t = ctypes.CFUNCTYPE(None, ctypes.c_uint)
        class Bus(ctypes.Structure):
            _fields_ = [("read", read_t), ("write", write_t), ("delay_ms", delay_t)]
        regs, writes, delays = {0: id_value, 0x2d: 0}, [], []
        def read(reg, value):
            value[0] = regs.get(reg, 0)
            return True
        def write(reg, value):
            writes.append((reg, value))
            if len(writes) == fail_at:
                return False
            regs[reg] = value
            if reg == 0x0a and not stuck:
                regs[0x2d] = 0x80 if value else 0
            return True
        callbacks = read_t(read), write_t(write), delay_t(delays.append)
        bus = Bus(*callbacks)
        result = self.lib.muse_tap_configure(ctypes.byref(bus))
        return result, regs, writes, delays

    def test_tap_enables_only_accelerometer_and_int1(self):
        ok, regs, writes, _ = self.configure()
        self.assertTrue(ok)
        self.assertEqual(regs[8], 1)  # gyro off, accel on
        self.assertEqual(regs[3], 0x14)  # 4g / 500 Hz
        self.assertEqual(regs[9], 0xc1)  # tap INT1 + command handshake
        self.assertEqual([v for r, v in writes if r == 0x12], [1, 2])

    def test_every_i2c_write_failure_stops_configuration(self):
        _, _, writes, _ = self.configure()
        for index in range(1, len(writes)+1):
            with self.subTest(index=index):
                ok, _, attempted, _ = self.configure(fail_at=index)
                self.assertFalse(ok)
                self.assertEqual(len(attempted), index)

    def test_missing_sensor_and_stuck_handshake_fail_bounded(self):
        ok, _, writes, _ = self.configure(id_value=0xff)
        self.assertFalse(ok)
        self.assertEqual(writes, [])
        ok, _, _, delays = self.configure(stuck=True)
        self.assertFalse(ok)
        self.assertEqual(len(delays), 100)
