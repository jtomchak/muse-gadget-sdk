"""Execute production ANCS attribute parser with fragmented/malformed payloads."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from test_link_ota import function_source
ROOT=Path(__file__).resolve().parents[1]
class ANCSTest(unittest.TestCase):
    def test_fragmented_bounded_attributes_uid_and_unknown_ids(self):
        source=(ROOT/'components/muse/muse_pocket_ancs.c').read_text()
        parser=function_source(source,'static void attributes(void)')
        with tempfile.TemporaryDirectory() as name:
            p=Path(name);test=p/'ancs.c';binary=p/'ancs'
            test.write_text('''#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <string.h>
static uint8_t s_buffer[256];static size_t s_size;static uint32_t s_uid=42,s_message_uid;static bool s_waiting,s_message;
static char s_title[33],s_body[161];static int s_mux;
static void muse_pocket_kick(void){}
#define portENTER_CRITICAL(x) ((void)(x))
#define portEXIT_CRITICAL(x) ((void)(x))
'''+parser+'''
int main(void){
    const uint8_t payload[]={0,42,0,0,0,1,3,0,'M','o','e',3,5,0,'H','e','l','l','o'};
    memcpy(s_buffer,payload,sizeof(payload));s_waiting=true;s_size=4;attributes();assert(s_waiting&&!s_message);
    s_size=12;attributes();assert(s_waiting&&!s_message);
    s_size=sizeof(payload);attributes();assert(!s_waiting&&s_message&&s_message_uid==42);assert(!strcmp(s_title,"Moe"));assert(!strcmp(s_body,"Hello"));
    s_message=false;s_waiting=true;s_buffer[1]=41;attributes();assert(!s_waiting&&!s_message);
    s_buffer[1]=42;s_buffer[5]=99;s_waiting=true;attributes();assert(!s_waiting&&!s_message);
    s_buffer[5]=1;s_buffer[6]=255;s_buffer[7]=255;s_waiting=true;attributes();assert(s_waiting&&!s_message);
    memcpy(s_buffer,payload,sizeof(payload));s_size=sizeof(payload)+1;s_buffer[s_size-1]=1;s_waiting=true;attributes();assert(!s_message);
    return 0;
}
''')
            built=subprocess.run([*shlex.split(os.environ.get('CC','cc')),'-std=c11','-Wall','-Wextra','-Werror',str(test),'-o',str(binary)],capture_output=True,text=True)
            self.assertEqual(built.returncode,0,built.stderr);run=subprocess.run([str(binary)],capture_output=True,text=True);self.assertEqual(run.returncode,0,run.stderr)
