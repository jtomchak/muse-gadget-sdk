"""Public initialization/write lifecycle, with production entry-point bodies."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from test_link_ota import function_source
ROOT=Path(__file__).resolve().parents[1]
class PocketInitializationTest(unittest.TestCase):
    def test_queue_accepts_only_initialized_authenticated_frames(self):
        source=(ROOT/'components/muse/muse_pocket.c').read_text()
        functions='\n'.join(function_source(source,name) for name in ['void muse_pocket_settings(', 'int muse_pocket_write(', 'esp_err_t muse_pocket_init('])
        with tempfile.TemporaryDirectory() as name:
            p=Path(name);test=p/'init.c';binary=p/'init';cj=ROOT/'managed_components/espressif__cjson/cJSON';muse=ROOT/'components/muse'
            test.write_text('''#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdatomic.h>
#include "pocket_model.h"
#include "pocket_frame.h"
#include "cJSON.h"
typedef int esp_err_t;typedef int nvs_handle_t;
#define ESP_OK 0
#define ESP_ERR_NO_MEM -12
#define NVS_READONLY 0
#define pdPASS 1
#define pdTRUE 1
#define portMAX_DELAY 0xffffffffu
#define MUSE_BIG_CAPS 42
static void *s_lock,*s_packets,*s_events,*s_worker;static pocket_rx_t *s_rx;static pocket_model_t *s_model;static uint8_t *s_avatar;
static atomic_bool s_initialized,s_secure;static atomic_uint s_generation;
typedef struct {uint32_t generation;uint16_t size;uint8_t data[512];} packet_t;
typedef struct {char event[32],detail[192];} event_t;
static packet_t queued;static int kicks;
static void *psram(size_t size){return calloc(1,size);}
static void *xSemaphoreCreateMutex(void){return (void*)1;}
static void xSemaphoreTake(void *h,unsigned t){(void)t;assert(h);}
static void xSemaphoreGive(void *h){assert(h);}
static void *xQueueCreate(unsigned n,size_t size){assert(n==8&&size);return (void*)1;}
static int xQueueSend(void *q,const void *data,int wait){(void)wait;assert(q);memcpy(&queued,data,sizeof(queued));return pdTRUE;}
static void muse_pocket_kick(void){kicks++;}
static int nvs_open(const char *name,int mode,nvs_handle_t *h){(void)name;(void)mode;(void)h;return -1;}
static int nvs_get_str(nvs_handle_t h,const char *key,char *text,size_t *size){(void)h;(void)key;(void)text;(void)size;return -1;}
static int nvs_get_blob(nvs_handle_t h,const char *key,void *bytes,size_t *size){(void)h;(void)key;(void)bytes;(void)size;return -1;}
static void nvs_close(nvs_handle_t h){(void)h;}
static bool muse_standby_clock_preference(void){return false;}
static bool muse_standby_tap_enabled(void){return true;}
static int muse_standby_shortcut(void){return 2;}
static void muse_standby_configure(const pocket_settings_t *s){assert(!s->clock&&s->tap&&s->shortcut==2);}
static void lock(int ms){(void)ms;}static void unlock(void){}
static struct {void (*display_lock)(int);void (*display_unlock)(void);} board={lock,unlock},*muse_board=&board;
static bool muse_tools_ui_set_presets(const pocket_preset_t *items,int count){(void)items;assert(count==0);return true;}
static void muse_pocket_ancs_enable(bool enabled){assert(!enabled);}
static const cJSON *get(const cJSON *o,const char *key){return cJSON_GetObjectItemCaseSensitive(o,key);}
static void worker(void *arg){(void)arg;}
static int xTaskCreateWithCaps(void (*task)(void*),const char *name,unsigned size,void *arg,int priority,void **handle,int caps){(void)name;(void)arg;assert(task==worker&&size==8192&&priority==3&&caps==MUSE_BIG_CAPS);*handle=(void*)1;return pdPASS;}
'''+functions+'''
int main(void){
    pocket_settings_t settings;muse_pocket_settings(&settings);assert(!strcmp(settings.name,"Moe"));
    uint8_t frame[13]={0xa1,1};assert(muse_pocket_write(frame,sizeof(frame))==-1);
    assert(muse_pocket_init()==ESP_OK);
    assert(muse_pocket_write(frame,sizeof(frame))==-1);
    atomic_store(&s_secure,true);atomic_store(&s_generation,42);
    assert(muse_pocket_write(frame,sizeof(frame))==0);assert(queued.generation==42&&queued.size==13&&kicks==1);
    assert(muse_pocket_write(frame,12)==-1);assert(muse_pocket_write(frame,513)==-1);
    muse_pocket_settings(&settings);assert(!settings.clock&&settings.tap&&settings.shortcut==2);
    return 0;
}
''')
            built=subprocess.run([*shlex.split(os.environ.get('CC','cc')),'-std=c11','-Wall','-Wextra','-Werror','-I'+str(muse),'-I'+str(cj),str(test),str(muse/'pocket_model.c'),str(cj/'cJSON.c'),'-o',str(binary)],capture_output=True,text=True)
            self.assertEqual(built.returncode,0,built.stderr);run=subprocess.run([str(binary)],capture_output=True,text=True);self.assertEqual(run.returncode,0,run.stderr)
