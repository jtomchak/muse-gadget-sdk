"""Exercise the production DMA completion path before and after LVGL waits."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

from test_link_ota import function_source

ROOT = Path(__file__).resolve().parents[1]


class LCDCompletionTest(unittest.TestCase):
    def test_early_delayed_and_failed_dma_chunks_release_exactly_one_band(self):
        source = (ROOT / 'components/muse/boards/muse_lcd_bands.c').read_text()
        functions = '\n'.join(function_source(source, name) for name in [
            'static bool IRAM_ATTR chunk_done(',
            'static bool IRAM_ATTR on_chunk_sent(',
            'static void wait_for_band(',
            'static void send_bands(',
        ])
        harness = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <setjmp.h>
typedef int BaseType_t;
typedef int lv_display_t;
typedef void *esp_lcd_panel_io_handle_t;
typedef int esp_lcd_panel_io_event_data_t;
typedef int esp_err_t;
typedef struct { int count, capacity; } sem_t;
typedef sem_t *SemaphoreHandle_t;
#define IRAM_ATTR
#define pdFALSE 0
#define pdTRUE 1
#define portMAX_DELAY 999
#define ESP_OK 0
#define portENTER_CRITICAL_SAFE(lock) ((void)(lock))
#define portEXIT_CRITICAL_SAFE(lock) ((void)(lock))
typedef struct { const uint8_t *data; int x1,y1,x2,y2; } band_t;
static sem_t free_sem, done_sem, call_sem;
static SemaphoreHandle_t s_chunk_free=&free_sem,s_band_done=&done_sem,s_call_done=&call_sem;
static uint8_t chunks[2][16];
static uint8_t *s_chunk[2]={chunks[0],chunks[1]};
static size_t s_chunk_bytes=16;
static int s_chunks_out,s_lock,s_panel,s_bands;
static void (*s_call)(void *);
static void *s_call_arg;
static band_t queued;
static bool available,delayed;
static int callbacks,draws,fail_at;
static jmp_buf sender_exit;
static bool on_chunk_sent(esp_lcd_panel_io_handle_t io,esp_lcd_panel_io_event_data_t *e,void *ctx);
static void give(sem_t *s){assert(s->count<s->capacity);s->count++;}
static void complete(void){assert(callbacks>0);callbacks--;on_chunk_sent(NULL,NULL,NULL);}
static void xSemaphoreTake(sem_t *s,unsigned wait){
    assert(wait==portMAX_DELAY);
    while(!s->count){assert(callbacks>0);complete();}
    s->count--;
}
static void xSemaphoreGive(sem_t *s){give(s);}
static void xSemaphoreGiveFromISR(sem_t *s,BaseType_t *woken){give(s);*woken=pdTRUE;}
static void xQueueReceive(int queue,band_t *b,unsigned wait){
    (void)queue;assert(wait==portMAX_DELAY);
    if(!available)longjmp(sender_exit,1);
    *b=queued;available=false;
}
static int esp_lcd_panel_draw_bitmap(int panel,int x1,int y1,int x2,int y2,void *data){
    (void)panel;assert(x1==0&&x2==2&&y2>y1&&data);
    draws++;
    if(draws==fail_at)return -1;
    callbacks++;
    if(!delayed)complete();
    return ESP_OK;
}
'''
        checks = r'''
int main(void){
    uint8_t pixels[40]={0};
    for(int late=0;late<2;late++)for(int failure=0;failure<=3;failure++){
        delayed=late;fail_at=failure;
        for(int round=0;round<2;round++){
            free_sem=(sem_t){2,2};done_sem=(sem_t){0,1};call_sem=(sem_t){0,1};
            callbacks=draws=0;s_chunks_out=0;
            queued=(band_t){pixels,0,0,2,10};available=true;
            if(!setjmp(sender_exit))send_bands(NULL);
            assert(draws==3);
            if(!late)assert(done_sem.count==1);
            wait_for_band(NULL);
            assert(callbacks==0&&s_chunks_out==0);
            assert(free_sem.count==2&&done_sem.count==0);
        }
    }
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            test = path / 'completion.c'
            binary = path / 'completion'
            test.write_text(harness + functions + checks)
            built = subprocess.run([
                *shlex.split(os.environ.get('CC', 'cc')), '-std=c11',
                '-Wall', '-Wextra', '-Werror', str(test), '-o', str(binary),
            ], capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=5)
            self.assertEqual(run.returncode, 0, run.stderr)
