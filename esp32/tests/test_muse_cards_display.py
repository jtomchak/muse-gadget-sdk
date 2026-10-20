"""Run card presentation and offline navigation against the production model."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from test_link_ota import function_source

ROOT = Path(__file__).resolve().parents[1]


class CardDisplayTest(unittest.TestCase):
    def test_offline_navigation_voice_priority_expiry_and_deletion(self):
        source = (ROOT / 'components/muse/muse_pocket.c').read_text()
        functions = '\n'.join(function_source(source, name) for name in [
            'static void cards_tick(', 'void muse_pocket_card_step(',
        ])
        harness = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <string.h>
#include <time.h>
#include "pocket_model.h"
#define pdTRUE 1
#define portMAX_DELAY 999
#define MUSE_MODE_IDLE 0
static pocket_model_t model,*s_model=&model;
static atomic_bool s_initialized;
static int s_card_index,s_lock,mode,page=-1,pokes;
static bool s_card_open,expired,asleep=true,lock_available=true;
static unsigned shown_count,shown_index;
static char shown_title[33],shown_body[161];
static time_t now=1800000000;
static time_t fake_time(time_t *out){if(out)*out=now;return now;}
#define time fake_time
static int xSemaphoreTake(int lock,unsigned wait){(void)lock;(void)wait;return lock_available;}
static void xSemaphoreGive(int lock){(void)lock;}
static int muse_state_mode(void *unused){(void)unused;return mode;}
static void muse_state_set_asleep(bool value){asleep=value;}
static void muse_state_poke(void){pokes++;}
static bool muse_ui_show_page(unsigned value){page=value;return true;}
static void muse_state_set_caption(const char *format,...){(void)format;assert(false);}
static void muse_ui_set_card(const char *title,const char *body,unsigned index,unsigned count,bool stale){
    strcpy(shown_title,title);strcpy(shown_body,body);shown_index=index;shown_count=count;expired=stale;
}
'''
        checks = r'''
int main(void){
    atomic_store(&s_initialized,true);
    model.card_count=2;
    strcpy(model.cards[0].title,"Packing");strcpy(model.cards[0].body,"Coffee and charger");
    strcpy(model.cards[1].title,"Meeting");model.cards[1].expires=now+60;
    cards_tick();assert(shown_count==2&&shown_index==0&&!strcmp(shown_title,"Packing"));
    assert(page==-1); /* background refresh doesn't steal navigation */
    muse_pocket_card_step(-1);cards_tick();assert(shown_index==1&&!expired);
    muse_pocket_card_step(1);cards_tick();assert(shown_index==0);
    s_card_open=true;mode=1;cards_tick();assert(page==-1&&s_card_open);
    mode=MUSE_MODE_IDLE;cards_tick();assert(page==2&&!s_card_open&&!asleep&&pokes>0);
    muse_pocket_card_step(1);now+=61;cards_tick();assert(expired);
    now=0;cards_tick();assert(expired); /* no valid clock */
    model.card_count=1;cards_tick();assert(shown_index==0&&shown_count==1&&!expired);
    model.card_count=0;page=-1;s_card_open=true;cards_tick();
    assert(shown_count==0&&shown_index==0&&page==-1&&!s_card_open);
    muse_pocket_card_step(-1);assert(s_card_index==0);
    lock_available=false;shown_count=99;cards_tick();assert(shown_count==99);
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            test = path / 'cards.c'
            binary = path / 'cards'
            test.write_text(harness + functions + checks)
            built = subprocess.run([
                *shlex.split(os.environ.get('CC', 'cc')), '-std=c11',
                '-Wall', '-Wextra', '-Werror', '-I'+str(ROOT/'components/muse'),
                str(test), '-o', str(binary),
            ], capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=5)
            self.assertEqual(run.returncode, 0, run.stderr)
