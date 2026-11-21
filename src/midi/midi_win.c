#ifdef _WIN32
#include "midi_platform.h"
#include <windows.h>
#include <mmsystem.h>
#include <stdlib.h>
#include <string.h>

#define MIDI_Q_CAP 1024

struct MidiPlat {
    HMIDIIN h_in;
    HMIDIOUT h_out;
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
}

MidiPlat *midi_plat_create(void) { return calloc(1, sizeof(MidiPlat)); }

void midi_plat_destroy(MidiPlat *m) {
    if (!m) return;
    midi_plat_close(m);
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
        midiOutClose(m->h_out);
        m->h_out = NULL;
    }
}

void midi_plat_send(MidiPlat *m, const uint8_t *bytes, uint32_t len) {
    if (!m->h_out || len == 0) return;
    if (bytes[0] == 0xF0) {
        MIDIHDR hdr;
        memset(&hdr, 0, sizeof(hdr));
        hdr.lpData = (LPSTR)bytes;
        hdr.dwBufferLength = len;
        if (midiOutPrepareHeader(m->h_out, &hdr, sizeof(hdr)) == MMSYSERR_NOERROR) {
            midiOutLongMsg(m->h_out, &hdr, sizeof(hdr));
            while ((hdr.dwFlags & MHDR_DONE) == 0) Sleep(1);
            midiOutUnprepareHeader(m->h_out, &hdr, sizeof(hdr));
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
#endif
