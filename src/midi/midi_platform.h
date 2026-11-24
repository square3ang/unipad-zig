#pragma once
#include <stdint.h>

typedef struct MidiPlat MidiPlat;

MidiPlat *midi_plat_create(void);
void midi_plat_destroy(MidiPlat *m);
uint32_t midi_plat_input_count(MidiPlat *m);
uint32_t midi_plat_output_count(MidiPlat *m);
int midi_plat_input_name(MidiPlat *m, uint32_t idx, char *buf, uint32_t cap);
int midi_plat_output_name(MidiPlat *m, uint32_t idx, char *buf, uint32_t cap);
int midi_plat_open_input(MidiPlat *m, uint32_t idx);
int midi_plat_open_output(MidiPlat *m, uint32_t idx);
void midi_plat_close(MidiPlat *m);
void midi_plat_send(MidiPlat *m, const uint8_t *bytes, uint32_t len);
int midi_plat_poll(MidiPlat *m, uint8_t out_msg[3]);
void midi_plat_wait(MidiPlat *m, uint64_t timeout_ns);
