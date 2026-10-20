"""Production voice sender with real Base64 and JSON, including full-size chunks."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from test_link_ota import function_source

ROOT = Path(__file__).resolve().parents[1]


class PocketVoiceSendTest(unittest.TestCase):
    def test_audio_round_trip_and_encoding_failure(self):
        flags = subprocess.run(['pkg-config', '--cflags', '--libs', 'mbedcrypto'],
                               capture_output=True, text=True)
        if flags.returncode:
            self.skipTest('Host Mbed TLS pkg-config package required')
        source = (ROOT / 'components/muse/muse_pocket.c').read_text()
        function = function_source(source, 'static void note_send(')
        cjson = ROOT / 'managed_components/espressif__cjson/cJSON'
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            harness = temp / 'voice.c'
            executable = temp / 'voice'
            harness.write_text(r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "mbedtls/base64.h"
#include "cJSON.h"
static uint8_t expected[120000];
static size_t expected_size, received, expected_frames;
static int chunks, ended, notices;
static bool fail_encode, fail_send;
static int checked_encode(unsigned char *out, size_t capacity, size_t *written,
                          const unsigned char *in, size_t size) {
    if (fail_encode) { *written=capacity+1; return -1; }
    return mbedtls_base64_encode(out, capacity, written, in, size);
}
static uint32_t pocket_crc32(const void *data, size_t size) {
    assert(size==expected_size && !memcmp(data,expected,size));
    return 1234;
}
static bool event_json(const char *name,cJSON *data,uint32_t generation) {
    assert(generation==7);
    assert(cJSON_GetObjectItemCaseSensitive(data,"turn")->valuedouble==123);
    if (!strcmp(name,"voice.begin")) assert(received==0);
    else if (!strcmp(name,"voice.chunk")) {
        assert(cJSON_GetObjectItemCaseSensitive(data,"offset")->valuedouble==received);
        const char *text=cJSON_GetObjectItemCaseSensitive(data,"data")->valuestring;
        unsigned char decoded[1024]; size_t size=0;
        assert(mbedtls_base64_decode(decoded,sizeof(decoded),&size,
                                    (const unsigned char *)text,strlen(text))==0);
        assert(size && size<=1024 && received+size<=expected_size);
        assert(!memcmp(expected+received,decoded,size));
        received+=size; chunks++;
        if (fail_send) { cJSON_Delete(data); return false; }
    } else {
        assert(!strcmp(name,"voice.end"));
        assert(received==expected_size);
        assert(cJSON_GetObjectItemCaseSensitive(data,"frames")->valuedouble==expected_frames);
        assert(cJSON_GetObjectItemCaseSensitive(data,"crc")->valuedouble==1234);
        ended++;
    }
    cJSON_Delete(data);return true;
}
static void notice(const char *title,const char *detail) {
    assert(title && detail); notices++;
}
#define mbedtls_base64_encode checked_encode
''' + function + r'''
#undef mbedtls_base64_encode
static void run(size_t frames,bool encoder_failure,bool send_failure) {
    expected_frames=frames; expected_size=(frames+1)/2;
    received=0;chunks=0;ended=0;notices=0;
    fail_encode=encoder_failure;fail_send=send_failure;
    for(size_t i=0;i<expected_size;i++)expected[i]=(uint8_t)(i*73);
    uint8_t *bytes=malloc(expected_size);assert(bytes);
    memcpy(bytes,expected,expected_size);
    note_send(bytes,frames,123,7);
    if (encoder_failure) assert(!chunks && !ended && notices==1);
    else if(send_failure) assert(chunks==1 && !ended && notices==1);
    else assert(received==expected_size && chunks==(int)((expected_size+1023)/1024)
                && ended==1 && !notices);
}
int main(void) {
    const size_t frames[]={1,2,3,5,2045,2046,2047,2048,2049,2050,240000};
    for(size_t i=0;i<sizeof(frames)/sizeof(frames[0]);i++)run(frames[i],false,false);
    run(2048,true,false);run(4096,false,true);
    return 0;
}
''')
            command = [*shlex.split(os.environ.get('CC', 'cc')), '-std=c11',
                       '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations',
                       '-fsanitize=address,undefined',
                       '-g', '-I'+str(cjson), str(harness), str(cjson/'cJSON.c'),
                       *shlex.split(flags.stdout), '-o', str(executable)]
            built = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            run = subprocess.run([str(executable)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
