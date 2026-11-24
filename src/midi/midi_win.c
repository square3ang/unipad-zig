#ifdef _WIN32
#include "midi_platform.h"
#include <windows.h>
#include <mmsystem.h>
#include <stdlib.h>
#include <string.h>

#define MIDI_Q_CAP 1024
#define MIDI_SYSEX_SLOTS 8
#define MIDI_SYSEX_MAX 256
#ifndef CREATE_WAITABLE_TIMER_HIGH_RESOLUTION
#define CREATE_WAITABLE_TIMER_HIGH_RESOLUTION 0x00000002
#endif

struct MidiPlat {
    HMIDIIN h_in;
    HMIDIOUT h_out;
    HANDLE wake_ev;
    HANDLE wait_timer;
    MIDIHDR sysex_hdr[MIDI_SYSEX_SLOTS];
    uint8_t sysex_buf[MIDI_SYSEX_SLOTS][MIDI_SYSEX_MAX];
    uint8_t sysex_in_flight[MIDI_SYSEX_SLOTS];
    uint32_t sysex_next;
    uint8_t q[MIDI_Q_CAP][3];
    volatile LONG q_head;
    volatile LONG q_tail;
};

static void CALLBACK in_proc(HMIDIIN h, UINT msg, DWORD_PTR inst, DWORD_PTR p1, DWORD_PTR p2) {
    (void)h; (void)p2;
    if (msg != MIM_DATA) return;
    MidiPlat *m = (MidiPlat *)inst;
    LONG h_idx = m->q_head;
    LONG t_idx = InterlockedCompareExchange(&m->q_tail, 0, 0);
    if (h_idx - t_idx >= MIDI_Q_CAP) return;
    m->q[h_idx % MIDI_Q_CAP][0] = (uint8_t)(p1 & 0xFF);
    m->q[h_idx % MIDI_Q_CAP][1] = (uint8_t)((p1 >> 8) & 0xFF);
    m->q[h_idx % MIDI_Q_CAP][2] = (uint8_t)((p1 >> 16) & 0xFF);
    InterlockedExchange(&m->q_head, h_idx + 1);
    if (m->wake_ev) SetEvent(m->wake_ev);
}

MidiPlat *midi_plat_create(void) {
    MidiPlat *m = calloc(1, sizeof(MidiPlat));
    if (!m) return NULL;
    m->wake_ev = CreateEventA(NULL, FALSE, FALSE, NULL);
    m->wait_timer = CreateWaitableTimerExW(NULL, NULL, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
    return m;
}

void midi_plat_destroy(MidiPlat *m) {
    if (!m) return;
    midi_plat_close(m);
    if (m->wait_timer) CloseHandle(m->wait_timer);
    if (m->wake_ev) CloseHandle(m->wake_ev);
    free(m);
}

uint32_t midi_plat_input_count(MidiPlat *m) { (void)m; return (uint32_t)midiInGetNumDevs(); }
uint32_t midi_plat_output_count(MidiPlat *m) { (void)m; return (uint32_t)midiOutGetNumDevs(); }

int midi_plat_input_name(MidiPlat *m, uint32_t idx, char *buf, uint32_t cap) {
    (void)m;
    MIDIINCAPSA caps;
    if (midiInGetDevCapsA(idx, &caps, sizeof(caps)) != MMSYSERR_NOERROR) return 0;
    size_t n = strlen(caps.szPname);
    if (n >= cap) n = cap - 1;
    memcpy(buf, caps.szPname, n);
    buf[n] = '\0';
    return (int)n;
}

int midi_plat_output_name(MidiPlat *m, uint32_t idx, char *buf, uint32_t cap) {
    (void)m;
    MIDIOUTCAPSA caps;
    if (midiOutGetDevCapsA(idx, &caps, sizeof(caps)) != MMSYSERR_NOERROR) return 0;
    size_t n = strlen(caps.szPname);
    if (n >= cap) n = cap - 1;
    memcpy(buf, caps.szPname, n);
    buf[n] = '\0';
    return (int)n;
}

int midi_plat_open_input(MidiPlat *m, uint32_t idx) {
    if (midiInOpen(&m->h_in, idx, (DWORD_PTR)in_proc, (DWORD_PTR)m, CALLBACK_FUNCTION) != MMSYSERR_NOERROR) {
        m->h_in = NULL;
        return 0;
    }
    midiInStart(m->h_in);
    return 1;
}

int midi_plat_open_output(MidiPlat *m, uint32_t idx) {
    if (midiOutOpen(&m->h_out, idx, 0, 0, CALLBACK_NULL) != MMSYSERR_NOERROR) {
        m->h_out = NULL;
        return 0;
    }
    return 1;
}

void midi_plat_close(MidiPlat *m) {
    if (m->h_in) {
        midiInStop(m->h_in);
        midiInReset(m->h_in);
        midiInClose(m->h_in);
        m->h_in = NULL;
    }
    if (m->h_out) {
        midiOutReset(m->h_out);
        for (int i = 0; i < MIDI_SYSEX_SLOTS; i++) {
            if (m->sysex_in_flight[i]) {
                midiOutUnprepareHeader(m->h_out, &m->sysex_hdr[i], sizeof(MIDIHDR));
                m->sysex_in_flight[i] = 0;
            }
        }
        midiOutClose(m->h_out);
        m->h_out = NULL;
    }
}

void midi_plat_send(MidiPlat *m, const uint8_t *bytes, uint32_t len) {
    if (!m->h_out || len == 0) return;
    if (bytes[0] == 0xF0) {
        if (len > MIDI_SYSEX_MAX) return;
        // Reclaim completed async SysEx headers without blocking.
        for (int i = 0; i < MIDI_SYSEX_SLOTS; i++) {
            if (m->sysex_in_flight[i] && (m->sysex_hdr[i].dwFlags & MHDR_DONE)) {
                midiOutUnprepareHeader(m->h_out, &m->sysex_hdr[i], sizeof(MIDIHDR));
                m->sysex_in_flight[i] = 0;
            }
        }
        int slot = -1;
        for (int i = 0; i < MIDI_SYSEX_SLOTS; i++) {
            uint32_t idx = (m->sysex_next + (uint32_t)i) % MIDI_SYSEX_SLOTS;
            if (!m->sysex_in_flight[idx]) { slot = (int)idx; break; }
        }
        if (slot < 0) {
            uint32_t idx = m->sysex_next % MIDI_SYSEX_SLOTS;
            int spins = 0;
            while ((m->sysex_hdr[idx].dwFlags & MHDR_DONE) == 0 && spins++ < 50) SwitchToThread();
            if ((m->sysex_hdr[idx].dwFlags & MHDR_DONE) == 0) return;
            midiOutUnprepareHeader(m->h_out, &m->sysex_hdr[idx], sizeof(MIDIHDR));
            m->sysex_in_flight[idx] = 0;
            slot = (int)idx;
        }
        m->sysex_next = ((uint32_t)slot + 1) % MIDI_SYSEX_SLOTS;
        memcpy(m->sysex_buf[slot], bytes, len);
        memset(&m->sysex_hdr[slot], 0, sizeof(MIDIHDR));
        m->sysex_hdr[slot].lpData = (LPSTR)m->sysex_buf[slot];
        m->sysex_hdr[slot].dwBufferLength = len;
        if (midiOutPrepareHeader(m->h_out, &m->sysex_hdr[slot], sizeof(MIDIHDR)) == MMSYSERR_NOERROR) {
            if (midiOutLongMsg(m->h_out, &m->sysex_hdr[slot], sizeof(MIDIHDR)) == MMSYSERR_NOERROR) {
                m->sysex_in_flight[slot] = 1;
            } else {
                midiOutUnprepareHeader(m->h_out, &m->sysex_hdr[slot], sizeof(MIDIHDR));
            }
        }
    } else if (len >= 3) {
        DWORD msg = (DWORD)bytes[0] | ((DWORD)bytes[1] << 8) | ((DWORD)bytes[2] << 16);
        midiOutShortMsg(m->h_out, msg);
    }
}

int midi_plat_poll(MidiPlat *m, uint8_t out_msg[3]) {
    LONG t_idx = m->q_tail;
    LONG h_idx = InterlockedCompareExchange(&m->q_head, 0, 0);
    if (t_idx == h_idx) return 0;
    memcpy(out_msg, m->q[t_idx % MIDI_Q_CAP], 3);
    InterlockedExchange(&m->q_tail, t_idx + 1);
    return 1;
}

void midi_plat_wait(MidiPlat *m, uint64_t timeout_ns) {
    if (!m) return;
    if (m->q_tail != InterlockedCompareExchange(&m->q_head, 0, 0)) return;
    if (m->wake_ev && m->wait_timer) {
        LARGE_INTEGER due;
        LONGLONG ticks = (LONGLONG)(timeout_ns / 100);
        if (ticks < 1) ticks = 1;
        due.QuadPart = -ticks;
        if (SetWaitableTimer(m->wait_timer, &due, 0, NULL, NULL, FALSE)) {
            HANDLE hs[2] = { m->wake_ev, m->wait_timer };
            WaitForMultipleObjects(2, hs, FALSE, INFINITE);
            return;
        }
    }
    DWORD ms = (DWORD)((timeout_ns + 999999) / 1000000);
    if (ms == 0) ms = 1;
    if (m->wake_ev) {
        WaitForSingleObject(m->wake_ev, ms);
    } else {
        Sleep(ms);
    }
}
#endif
