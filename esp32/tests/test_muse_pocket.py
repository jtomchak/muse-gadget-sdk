"""Run production framing and persisted model against the Swift wire contract."""
import ctypes as c
import json
import os
from pathlib import Path
import shlex
import struct
import subprocess
import tempfile
import unittest
import zlib
ROOT=Path(__file__).resolve().parents[1]
MUSE=ROOT/'components/muse'
class RX(c.Structure):
    _fields_=[('data',c.c_uint8*24576),('size',c.c_size_t),('transfer',c.c_uint16),('total',c.c_uint16),('next',c.c_uint16),('crc',c.c_uint32),('began_ms',c.c_uint32)]
class PocketTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp=tempfile.TemporaryDirectory();p=Path(cls.tmp.name);cj=ROOT/'managed_components/espressif__cjson/cJSON'
        bridge=p/'bridge.c';bridge.write_text('''#include "pocket_model.h"
#include "cJSON.h"
static pocket_model_t m;
void reset(void){pocket_model_init(&m);}
int apply(const char *method,const char *params){char err[128];cJSON *p=cJSON_Parse(params);int r=pocket_model_apply(&m,method,p,err,sizeof(err));cJSON_Delete(p);return r;}
const char *snapshot(void){static char out[12000];cJSON *o=pocket_model_json(&m);cJSON_PrintPreallocated(o,out,sizeof(out),0);cJSON_Delete(o);return out;}
''')
        objects=[]
        for i,source in enumerate([MUSE/'pocket_model.c',MUSE/'muse_adpcm.c',cj/'cJSON.c',bridge]):
            obj=p/f'{i}.o';subprocess.run([*shlex.split(os.environ.get('CC','cc')),'-std=c11','-Wall','-Wextra','-Werror','-fPIC','-I'+str(MUSE),'-I'+str(cj),'-c',str(source),'-o',str(obj)],check=True,capture_output=True);objects.append(str(obj))
        lib=p/'pocket.so';subprocess.run([*shlex.split(os.environ.get('CXX','c++')),'-std=c++17','-Wall','-Wextra','-Werror','-shared','-fPIC',str(MUSE/'pocket_frame.cpp'),*objects,'-o',str(lib)],check=True,capture_output=True)
        cls.lib=c.CDLL(str(lib));cls.lib.pocket_frame_receive.argtypes=[c.POINTER(RX),c.c_void_p,c.c_size_t,c.c_uint32];cls.lib.pocket_frame_encode.argtypes=[c.c_void_p,c.c_size_t,c.c_uint8,c.c_uint16,c.c_uint16,c.c_void_p,c.c_size_t];cls.lib.pocket_frame_encode.restype=c.c_size_t;cls.lib.apply.argtypes=[c.c_char_p,c.c_char_p];cls.lib.snapshot.restype=c.c_char_p;cls.lib.pocket_night_contains.argtypes=[c.c_bool,c.c_int,c.c_int,c.c_int];cls.lib.pocket_night_contains.restype=c.c_bool
    @classmethod
    def tearDownClass(cls):cls.tmp.cleanup()
    def setUp(self):self.lib.reset()
    def apply(self,m,p):return self.lib.apply(m.encode(),json.dumps(p,ensure_ascii=False).encode())
    def snapshot(self):return json.loads(self.lib.snapshot())
    def packets(self,data,mtu=185,kind=0xa1,transfer=42):
        out=c.create_string_buffer(512);result=[]
        for i in range((len(data)+mtu-13)//(mtu-12)):
            n=self.lib.pocket_frame_encode(out,mtu,kind,transfer,i,data,len(data));self.assertGreater(n,0);result.append(out.raw[:n])
        return result
    def consume(self,rx,p,now=0):return self.lib.pocket_frame_receive(c.byref(rx),p,len(p),now)
    def test_swift_fixture(self):
        packet=bytes.fromhex('a10134120000010086a6103668656c6c6f');rx=RX();self.assertEqual(self.consume(rx,packet),1);self.assertEqual(bytes(rx.data[:rx.size]),b'hello');self.assertEqual(self.packets(b'hello',20,transfer=0x1234),[packet])
    def test_mtu_roundtrips_and_crc(self):
        for mtu in [20,64,185,512]:
            data=bytes(i%251 for i in range(12000));rx=RX();packets=self.packets(data,mtu)
            for i,p in enumerate(packets):self.assertEqual(self.consume(rx,p),int(i==len(packets)-1))
            self.assertEqual(bytes(rx.data[:rx.size]),data);self.assertEqual(struct.unpack('<I',packets[0][8:12])[0],zlib.crc32(data))
    def test_missing_damage_timeout(self):
        packets=self.packets(b'12345678901234567890',20);rx=RX();self.consume(rx,packets[0]);self.assertEqual(self.consume(rx,packets[2]),-1)
        rx=RX();self.consume(rx,packets[0]);self.assertEqual(self.consume(rx,packets[1],31001),-1)
        rx=RX();bad=bytearray(packets[0]);bad[-1]^=1;self.consume(rx,bytes(bad));self.consume(rx,packets[1]);self.assertEqual(self.consume(rx,packets[2]),-1)
    def test_new_transfer_replaces_partial(self):
        rx=RX();self.consume(rx,self.packets(b'long incomplete message',20)[0]);self.assertEqual(self.consume(rx,self.packets(b'new',20,transfer=3)[0]),1);self.assertEqual(bytes(rx.data[:rx.size]),b'new')
    def test_malformed_and_wrong_direction(self):
        for p in [b'',bytes(12),bytes(13),self.packets(b'hi',kind=0xa2)[0]]:self.assertEqual(self.consume(RX(),p),-1)
    def test_limits(self):
        out=c.create_string_buffer(512);self.assertEqual(self.lib.pocket_frame_encode(out,512,0xa1,1,0,b'x'*24577,24577),0);self.assertEqual(self.lib.pocket_frame_encode(out,12,0xa1,1,0,b'x',1),0)
    def test_uptime_wrap(self):
        rx=RX();packets=self.packets(b'1234567890',20);self.assertEqual(self.consume(rx,packets[0],0xfffffff0),0);self.assertEqual(self.consume(rx,packets[1],0x20),1)
    def test_settings_atomic_validation(self):
        settings=self.snapshot()['settings'];settings.update(name='Desk Moe',tap=True,tilt=True,night=True,notifications=True,relay=True,clock24=False);self.assertEqual(self.apply('settings.set',settings),1)
        for k,v in [('shortcut',3),('tapThreshold',2001),('name','☕'*9),('clock',1),('nightStart',1440),('timezone','')]:
            invalid=dict(settings);invalid[k]=v;self.assertEqual(self.apply('settings.set',invalid),-1);self.assertEqual(self.snapshot()['settings'],settings)
        invalid=dict(settings);del invalid['tap'];self.assertEqual(self.apply('settings.set',invalid),-1)
    def test_card_capacity_replace_delete(self):
        for i in range(8):self.assertEqual(self.apply('card.put',dict(id=str(i),title='Card',body='☕ coffee',source='Tests',expires=0)),3)
        item=dict(id='9',title='Ninth',body='',source='',expires=0);self.assertEqual(self.apply('card.put',item),-1);item['id']='0';self.assertEqual(self.apply('card.put',item),3);self.assertEqual(len(self.snapshot()['cards']),8);self.assertEqual(self.apply('card.delete',{'id':'0'}),3);self.assertEqual(len(self.snapshot()['cards']),7);item['expires']=253402300800;self.assertEqual(self.apply('card.put',item),-1)
    def test_preset_start_and_invalid_duration(self):
        item=dict(id='tea',title='Tea',detail='Steep',seconds=180);self.assertEqual(self.apply('preset.put',item),2);before=self.snapshot();self.assertEqual(self.apply('timer.start',{'id':'tea'}),4);self.assertEqual(self.snapshot(),before);self.assertEqual(self.apply('timer.start',{'id':'missing'}),-1)
        for seconds in [0,86401,1.5,'180']:
            item['seconds']=seconds;self.assertEqual(self.apply('preset.put',item),-1)
        self.assertEqual(self.apply('preset.delete',{'id':'tea'}),2);self.assertEqual(self.snapshot()['presets'],[])
    def test_night_boundaries(self):
        for m,v in [(1320,True),(0,True),(419,True),(420,False),(1319,False)]:self.assertEqual(self.lib.pocket_night_contains(True,1320,420,m),v)
        self.assertFalse(self.lib.pocket_night_contains(True,420,420,420));self.assertFalse(self.lib.pocket_night_contains(False,1320,420,0))
    def test_unknown_method_bad_parameters(self):
        self.assertEqual(self.apply('wipe_everything',{}),-1);self.assertEqual(self.apply('hello',[]),-1)

    def test_c_codec_swift_fixture(self):
        class State(c.Structure):_fields_=[('pred',c.c_int16),('index',c.c_int8)]
        pcm=(c.c_int16*8)(-32768,-12000,-1000,0,1000,12000,32767,0);out=(c.c_uint8*4)();state=State()
        self.lib.muse_adpcm_encode_block(c.byref(state),pcm,8,out);self.assertEqual(bytes(out).hex(),'ff5f77d7')
    def test_json_depth_is_bounded_before_recursive_parse(self):
        self.lib.pocket_json_depth_valid.argtypes=[c.c_char_p,c.c_size_t];self.lib.pocket_json_depth_valid.restype=c.c_bool
        for text,valid in [(b'{"caption":"[{\\\"}"}',True),(b'['*17+b']'*17,False),(b'['*16+b']'*16,True),(b'{"x":"unterminated}',False),(b'{}\0',False)]:
            self.assertEqual(self.lib.pocket_json_depth_valid(text,len(text)),valid)
