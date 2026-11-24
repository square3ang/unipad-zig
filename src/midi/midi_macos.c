#ifdef __APPLE__
#include "midi_platform.h"
#include <CoreMIDI/CoreMIDI.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define MIDI_Q_CAP 1024

struct MidiPlat {
    MIDIClientRef client;
    MIDIPortRef in_port;
    MIDIPortRef out_port;
    MIDIEndpointRef connected_src;
    MIDIEndpointRef connected_dst;
    dispatch_semaphore_t wake_sem;
    uint8_t q[MIDI_Q_CAP][3];
    _Atomic uint32_t q_head;
    _Atomic uint32_t q_tail;
};

static void read_proc(const MIDIPacketList *list, void *refcon, void *src_refcon) {
    (void)src_refcon;
    MidiPlat *m = (MidiPlat *)refcon;
    int pushed = 0;
    const MIDIPacket *pkt = &list->packet[0];
    for (UInt32 i = 0; i < list->numPackets; i++) {
        UInt16 off = 0;
        while (off < pkt->length) {
            uint8_t st = pkt->data[off];
            if (st == 0xF0) {
                while (off < pkt->length && pkt->data[off] != 0xF7) off++;
                if (off < pkt->length) off++;
                continue;
            }
            if ((st & 0x80) == 0) { off++; continue; }
            uint8_t kind = st & 0xF0;
            if ((kind == 0x80 || kind == 0x90 || kind == 0xB0) && off + 2 < pkt->length) {
                uint32_t h = atomic_load_explicit(&m->q_head, memory_order_relaxed);
                uint32_t t = atomic_load_explicit(&m->q_tail, memory_order_acquire);
                if (h - t < MIDI_Q_CAP) {
                    m->q[h % MIDI_Q_CAP][0] = st;
                    m->q[h % MIDI_Q_CAP][1] = pkt->data[off + 1];
                    m->q[h % MIDI_Q_CAP][2] = pkt->data[off + 2];
                    atomic_store_explicit(&m->q_head, h + 1, memory_order_release);
                    pushed = 1;
                }
                off += 3;
            } else {
                off++;
            }
        }
        pkt = MIDIPacketNext(pkt);
    }
    if (pushed && m->wake_sem) dispatch_semaphore_signal(m->wake_sem);
}

static int endpoint_name(MIDIEndpointRef ep, char *buf, uint32_t cap) {
    CFStringRef name = NULL;
    if (MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &name) != noErr || !name) {
        if (MIDIObjectGetStringProperty(ep, kMIDIPropertyName, &name) != noErr || !name) return 0;
    }
    Boolean ok = CFStringGetCString(name, buf, (CFIndex)cap, kCFStringEncodingUTF8);
    CFRelease(name);
    return ok ? (int)strlen(buf) : 0;
}

MidiPlat *midi_plat_create(void) {
    MidiPlat *m = calloc(1, sizeof(*m));
    if (!m) return NULL;
    m->wake_sem = dispatch_semaphore_create(0);
    MIDIClientCreate(CFSTR("unipad-zig"), NULL, NULL, &m->client);
    MIDIInputPortCreate(m->client, CFSTR("in"), read_proc, m, &m->in_port);
    MIDIOutputPortCreate(m->client, CFSTR("out"), &m->out_port);
    return m;
}

void midi_plat_destroy(MidiPlat *m) {
    if (!m) return;
    midi_plat_close(m);
    if (m->in_port) MIDIPortDispose(m->in_port);
    if (m->out_port) MIDIPortDispose(m->out_port);
    if (m->client) MIDIClientDispose(m->client);
    if (m->wake_sem) dispatch_release(m->wake_sem);
    free(m);
}

uint32_t midi_plat_input_count(MidiPlat *m) { (void)m; return (uint32_t)MIDIGetNumberOfSources(); }
uint32_t midi_plat_output_count(MidiPlat *m) { (void)m; return (uint32_t)MIDIGetNumberOfDestinations(); }

int midi_plat_input_name(MidiPlat *m, uint32_t idx, char *buf, uint32_t cap) {
    (void)m;
    return endpoint_name(MIDIGetSource(idx), buf, cap);
}

int midi_plat_output_name(MidiPlat *m, uint32_t idx, char *buf, uint32_t cap) {
    (void)m;
    return endpoint_name(MIDIGetDestination(idx), buf, cap);
}

int midi_plat_open_input(MidiPlat *m, uint32_t idx) {
    MIDIEndpointRef src = MIDIGetSource(idx);
    if (!src) return 0;
    if (MIDIPortConnectSource(m->in_port, src, NULL) != noErr) return 0;
    m->connected_src = src;
    return 1;
}

int midi_plat_open_output(MidiPlat *m, uint32_t idx) {
    MIDIEndpointRef dst = MIDIGetDestination(idx);
    if (!dst) return 0;
    m->connected_dst = dst;
    return 1;
}

void midi_plat_close(MidiPlat *m) {
    if (m->connected_src) {
        MIDIPortDisconnectSource(m->in_port, m->connected_src);
        m->connected_src = 0;
    }
    m->connected_dst = 0;
}

void midi_plat_send(MidiPlat *m, const uint8_t *bytes, uint32_t len) {
    if (!m->connected_dst || len == 0 || len > 256) return;
    uint8_t storage[512];
    MIDIPacketList *list = (MIDIPacketList *)storage;
    MIDIPacket *pkt = MIDIPacketListInit(list);
    MIDIPacketListAdd(list, sizeof(storage), pkt, 0, len, bytes);
    MIDISend(m->out_port, m->connected_dst, list);
}

int midi_plat_poll(MidiPlat *m, uint8_t out_msg[3]) {
    uint32_t t = atomic_load_explicit(&m->q_tail, memory_order_relaxed);
    uint32_t h = atomic_load_explicit(&m->q_head, memory_order_acquire);
    if (t == h) return 0;
    memcpy(out_msg, m->q[t % MIDI_Q_CAP], 3);
    atomic_store_explicit(&m->q_tail, t + 1, memory_order_release);
    return 1;
}

void midi_plat_wait(MidiPlat *m, uint64_t timeout_ns) {
    if (!m || !m->wake_sem) return;
    uint32_t t = atomic_load_explicit(&m->q_tail, memory_order_relaxed);
    uint32_t h = atomic_load_explicit(&m->q_head, memory_order_acquire);
    if (t != h) return;
    dispatch_semaphore_wait(m->wake_sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeout_ns));
}
#endif
