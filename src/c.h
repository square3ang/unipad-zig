#include <SDL3/SDL.h>
#include <SDL3_ttf/SDL_ttf.h>
#include <archive.h>
#include <archive_entry.h>
#define STB_VORBIS_HEADER_ONLY
#include "stb_vorbis.c"
#include "dr_wav.h"
#include "dr_flac.h"
#include "dr_mp3.h"
#include "sokol_gfx.h"
#include "render/render_backend.h"
#ifdef __linux__
#define NFD_PORTAL
#include <alsa/asoundlib.h>
#else
#include <portaudio.h>
#ifdef _WIN32
#include <pa_win_wasapi.h>
#endif
#include "midi/midi_platform.h"
#endif
#include "nfd.h"
#include "nfd_sdl3.h"
