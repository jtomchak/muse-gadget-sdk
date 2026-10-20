"""Explicit paired-gadget authorization; no secrets from snapshots or stale links."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from test_link_ota import function_source

ROOT = Path(__file__).resolve().parents[1]


class PocketAuthorizationTest(unittest.TestCase):
    def test_authorization_requires_current_link_and_preserves_vm_scope(self):
        source = (ROOT / 'components/muse/muse_pocket.c').read_text()
        functions = '\n'.join(function_source(source, name) for name in
                              ['static cJSON *authorize_phone(', 'static void command('])
        cjson = ROOT / 'managed_components/espressif__cjson/cJSON'
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory)
            test, executable = p/'auth.c', p/'auth'
            test.write_text(r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdatomic.h>
#include "cJSON.h"
static atomic_bool s_secure;
static atomic_uint s_generation;
static bool linked,wifi,host_ok,lookup_ok,empty_vm,empty_token,drop_link,change_generation;
static int lookups,cleared;
static bool muse_link_hatch_linked(void){return linked;}
static bool muse_wifi_connected(void){return wifi;}
static bool muse_link_phone_muse_host(char *host,size_t size){
    if(!host_ok)return false;
    snprintf(host,size,"paired.muse.invalid");return true;
}
static bool muse_link_hatch_vm(const char *want,char *vm,size_t cap,char *name,size_t ncap,char **token){
    assert(!*want);lookups++;
    snprintf(vm,cap,"%s",empty_vm?"":"paired-vm");snprintf(name,ncap,"Fixture");
    *token=strdup(empty_token?"":"fixture-vm-token");
    if(drop_link)atomic_store(&s_secure,false);
    if(change_generation)atomic_fetch_add(&s_generation,1);
    return lookup_ok;
}
static void mbedtls_platform_zeroize(void *ptr,size_t size){memset(ptr,0,size);cleared++;}
static void checked_free(void *ptr){
    if(ptr)assert(*(char*)ptr==0);free(ptr);
}
#define free checked_free
''' + functions.split('static void command(void)')[0] + r'''
#undef free
static void reset(void){
    s_secure=true;s_generation=7;linked=wifi=host_ok=lookup_ok=true;
    empty_vm=empty_token=drop_link=change_generation=false;lookups=cleared=0;
}
static void rejected(void){
    const char *failure=NULL;cJSON *result=authorize_phone(7,&failure);
    assert(!result&&failure&&*failure);
}
#define POCKET_QUERY 0
#define POCKET_RESPONSE 0xa2
typedef struct{int settings;}pocket_model_t;
static pocket_model_t model,*s_model=&model;
static void *s_lock;
static struct{uint8_t data[2048];size_t size;}rx,*s_rx=&rx;
static char sent[2048];
static const char *str(const cJSON *o,const char *key){
    const cJSON *v=cJSON_GetObjectItemCaseSensitive(o,key);return cJSON_IsString(v)?v->valuestring:NULL;
}
static const cJSON *get(const cJSON *o,const char *key){return cJSON_GetObjectItemCaseSensitive(o,key);}
static bool num(const cJSON *o,const char *key,int64_t min,int64_t max,int64_t *out){
    const cJSON *v=get(o,key);if(!cJSON_IsNumber(v)||v->valuedouble<min||v->valuedouble>max)return false;
    *out=(int64_t)v->valuedouble;return true;
}
static bool pocket_json_depth_valid(const void *bytes,size_t size){return bytes&&size;}
static void *psram(size_t size){return calloc(1,size);}
static void xSemaphoreTake(void *h,int t){(void)h;(void)t;}
static void xSemaphoreGive(void *h){(void)h;}
#define portMAX_DELAY -1
static void muse_pocket_settings(void *s){(void)s;}
static int pocket_model_apply(void *candidate,const char *method,const cJSON *params,char *error,size_t cap){
    (void)candidate;(void)params;if(!strcmp(method,"hello"))return POCKET_QUERY;
    snprintf(error,cap,"Unsupported method");return -1;
}
static const char *apply(int action,void *model,const cJSON *params){(void)action;(void)model;(void)params;return NULL;}
static cJSON *snapshot(void){return cJSON_CreateObject();}
static bool send_json(uint8_t kind,const cJSON *response,uint32_t generation){
    assert(kind==POCKET_RESPONSE&&generation==7);char *json=cJSON_PrintUnformatted(response);
    assert(strlen(json)<sizeof(sent));strcpy(sent,json);free(json);return true;
}
''' + 'static void command(void)' + functions.split('static void command(void)', 1)[1] + r'''
static cJSON *request(const char *method){
    snprintf((char*)rx.data,sizeof(rx.data),"{\"v\":1,\"id\":\"fixture\",\"method\":\"%s\",\"params\":{}}",method);
    rx.size=strlen((char*)rx.data);command();return cJSON_Parse(sent);
}
int main(void){
    reset();s_secure=false;rejected();assert(lookups==0);
    reset();s_generation=8;rejected();assert(lookups==0);
    reset();linked=false;rejected();assert(lookups==0);
    reset();wifi=false;rejected();assert(lookups==0);
    reset();host_ok=false;rejected();assert(lookups==0);
    reset();lookup_ok=false;rejected();assert(cleared==1);
    reset();empty_vm=true;rejected();assert(cleared==1);
    reset();empty_token=true;rejected();assert(cleared==1);
    reset();drop_link=true;rejected();assert(cleared==1);
    reset();change_generation=true;rejected();assert(cleared==1);
    reset();const char *failure=NULL;cJSON *result=authorize_phone(7,&failure);
    assert(result&&!failure&&cleared==1);
    assert(!strcmp(str(result,"host"),"paired.muse.invalid"));
    assert(!strcmp(str(result,"vm"),"paired-vm"));
    assert(!strcmp(str(result,"token"),"fixture-vm-token"));
    assert(cJSON_GetArraySize(result)==3);cJSON_Delete(result);
    reset();result=request("hello");assert(lookups==0&&get(result,"ok")->valueint);
    assert(!str(get(result,"result"),"token"));cJSON_Delete(result);
    reset();result=request("muse.authorize");assert(lookups==1&&get(result,"ok")->valueint);
    assert(!strcmp(str(get(result,"result"),"token"),"fixture-vm-token"));
    assert(cleared==2);cJSON_Delete(result);
    reset();wifi=false;result=request("muse.authorize");assert(!get(result,"ok")->valueint);
    assert(!get(result,"result")&&lookups==0);cJSON_Delete(result);
    return 0;
}
''')
            built = subprocess.run([*shlex.split(os.environ.get('CC', 'cc')), '-std=c11',
                                    '-D_POSIX_C_SOURCE=200809L', '-Wall', '-Wextra', '-Werror',
                                    '-Wno-unused-variable', '-Wno-deprecated-declarations',
                                    '-fsanitize=address,undefined', '-I'+str(cjson),
                                    str(test), str(cjson/'cJSON.c'), '-o', str(executable)],
                                   capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            ran = subprocess.run([str(executable)], capture_output=True, text=True)
            self.assertEqual(ran.returncode, 0, ran.stderr)
