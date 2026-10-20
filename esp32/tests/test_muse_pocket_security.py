"""Protected GATT must synchronize worker security on a bonded reconnect."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from test_link_ota import function_source

ROOT = Path(__file__).resolve().parents[1]


class PocketSecurityTest(unittest.TestCase):
    def test_current_link_security_overrides_stale_cache_without_trusting_bonds(self):
        source = (ROOT / 'components/muse/muse_ble.c').read_text()
        functions = '\n'.join(function_source(source, name) for name in [
            'static bool pocket_connection_secure(', 'static int pocket_access(',
        ])
        harness = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdatomic.h>
#include <string.h>
#define BLE_GATT_ACCESS_OP_READ_CHR 1
#define BLE_GATT_ACCESS_OP_WRITE_CHR 2
#define BLE_ATT_ERR_INSUFFICIENT_AUTHEN 5
#define BLE_ATT_ERR_INSUFFICIENT_RES 17
#define BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN 13
#define BLE_ATT_ERR_UNLIKELY 14
struct ble_gap_conn_desc { struct {bool encrypted,authenticated,bonded;} sec_state; } actual;
struct ble_gatt_access_ctxt {int op;void *om;};
static uint16_t s_conn=1;
static atomic_bool s_secure;
static bool worker_secure,lookup_fails,queue_full;
static int writes,reads;
static int ble_gap_conn_find(uint16_t handle,struct ble_gap_conn_desc *out){
    if(handle!=1||lookup_fails)return -1;
    *out=actual;return 0;
}
static void muse_pocket_connection(uint16_t handle,bool secure){assert(handle==1);worker_secure=secure;}
static int os_mbuf_append(void *om,const void *data,size_t size){
    (void)om;assert(worker_secure&&atomic_load(&s_secure));
    assert(size==20&&!memcmp(data,"{\"v\":1,\"ready\":true}",size));reads++;return 0;
}
static int ble_hs_mbuf_to_flat(void *om,void *data,size_t cap,uint16_t *size){
    (void)om;assert(cap==512);memset(data,0,13);*size=13;return 0;
}
static int muse_pocket_write(const uint8_t *data,size_t size){
    assert(data&&size==13);writes++;return worker_secure&&!queue_full?0:-1;
}
'''
        checks = r'''
int main(void){
    struct ble_gatt_access_ctxt read={BLE_GATT_ACCESS_OP_READ_CHR,0};
    struct ble_gatt_access_ctxt write={BLE_GATT_ACCESS_OP_WRITE_CHR,0};
    actual.sec_state.encrypted=actual.sec_state.authenticated=actual.sec_state.bonded=true;
    /* Actual captured failure: protected read succeeds, cache and worker false. */
    assert(pocket_access(1,0,&read,0)==0&&reads==1&&worker_secure);
    assert(pocket_access(1,0,&write,0)==0&&writes==1);
    atomic_store(&s_secure,false);worker_secure=false;
    assert(pocket_access(1,0,&write,0)==0&&writes==2&&worker_secure);
    /* Having a bond is never sufficient without current authenticated encryption. */
    actual.sec_state.encrypted=false;
    assert(pocket_access(1,0,&write,0)==BLE_ATT_ERR_INSUFFICIENT_AUTHEN&&writes==2);
    assert(!atomic_load(&s_secure)&&!worker_secure);
    actual.sec_state.encrypted=true;actual.sec_state.authenticated=false;
    assert(pocket_access(1,0,&read,0)==BLE_ATT_ERR_INSUFFICIENT_AUTHEN&&reads==1);
    actual.sec_state.authenticated=true;lookup_fails=true;
    assert(pocket_access(1,0,&write,0)==BLE_ATT_ERR_INSUFFICIENT_AUTHEN);
    lookup_fails=false;
    assert(pocket_access(2,0,&write,0)==BLE_ATT_ERR_INSUFFICIENT_AUTHEN);
    queue_full=true;
    assert(pocket_access(1,0,&write,0)==BLE_ATT_ERR_INSUFFICIENT_RES&&worker_secure);
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            test = path/'security.c'
            binary = path/'security'
            test.write_text(harness+functions+checks)
            built = subprocess.run([
                *shlex.split(os.environ.get('CC', 'cc')), '-std=c11',
                '-Wall', '-Wextra', '-Werror', str(test), '-o', str(binary),
            ], capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=5)
            self.assertEqual(run.returncode, 0, run.stderr)
