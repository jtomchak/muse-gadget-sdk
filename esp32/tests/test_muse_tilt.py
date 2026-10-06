"""Production accelerometer-only wake: arming, stable tilt, timing and wrap."""
import ctypes as c
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
class Tilt(c.Structure):_fields_=[('flat',c.c_bool),('samples',c.c_uint),('last_ms',c.c_uint32)]
class TiltTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp=tempfile.TemporaryDirectory();lib=Path(cls.tmp.name)/'tilt.so';src=Path(__file__).resolve().parents[1]/'components/muse/muse_tilt.c'
        subprocess.run([*shlex.split(os.environ.get('CC','cc')),'-std=c11','-Wall','-Wextra','-Werror','-fPIC','-shared',str(src),'-o',str(lib)],check=True,capture_output=True)
        cls.lib=c.CDLL(str(lib));cls.lib.muse_tilt_update.argtypes=[c.POINTER(Tilt),c.c_int16,c.c_uint32];cls.lib.muse_tilt_update.restype=c.c_bool
    @classmethod
    def tearDownClass(cls):cls.tmp.cleanup()
    def update(self,s,z,ms):return self.lib.muse_tilt_update(c.byref(s),z,ms)
    def test_flat_then_stable_lift(self):
        s=Tilt();self.assertFalse(self.update(s,8192,100));self.assertFalse(self.update(s,0,200));self.assertTrue(self.update(s,0,300));self.assertFalse(self.update(s,0,400))
    def test_vertical_start_never_arms(self):
        s=Tilt()
        for ms in range(100,1000,100):self.assertFalse(self.update(s,0,ms))
    def test_fast_samples_and_small_movements_do_not_wake(self):
        s=Tilt();self.update(s,8192,100);self.assertFalse(self.update(s,0,101));self.assertFalse(self.update(s,0,102));self.assertFalse(self.update(s,4500,200));self.assertFalse(self.update(s,0,300));self.assertTrue(self.update(s,0,400))
    def test_negative_gravity_and_uptime_wrap(self):
        s=Tilt(last_ms=0xffffff00);self.assertFalse(self.update(s,-8192,0xffffff80));self.assertFalse(self.update(s,-1000,0x10));self.assertTrue(self.update(s,-1000,0x90))
