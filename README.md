# unipad-zig

Native Zig UniPad / UniPack player with low-latency audio, GPU-accelerated rendering, and full bidirectional Novation Launchpad MIDI support.

## Features

- **UniPack & Ableton Live playback**:
  - Loads standard `.zip` / `.uni` archives and unpacked folders (`info`, `keySound`, `keyLED`, `autoPlay`), including UTF-8/UTF-16 BOM and `\r`/`\n`/`\r\n` line endings.
  - Direct Ableton Live (`.als`, Ableton project `.zip`, or folder) loading & conversion to portable UniPack `.zip`: streaming gzip XML parser, Drum Rack + Instrument Rack sample mapping, MIDI Effect Rack lightshow simulator (`Pitch`, `Chord`, `Velocity`, `Note Length`, `Arpeggiator`), and Arrangement `MidiClip` AutoPlay extraction.
- **Low-latency audio**:
  - Linux: Direct 1-period ALSA output (`libasound`, no PortAudio) with RT priority (`rtkit`), SIMD steady-state mixer, and toggleable Anti-Pop DSP (micro fade-in/out, soft stop, DC blocker).
  - Windows / macOS: PortAudio (ASIO / WASAPI Exclusive / CoreAudio).
- **Hardware Launchpad MIDI (all models)**:
  - Launchpad Original / S / Mini, MK2, Pro, Pro CFW, CoreFW RGB, CoreFW S, X, Mini MK3, Pro MK3.
  - Auto-detection via USB VID/PID/serial/name, manual model & MIDI port dropdowns.
- **Play modes**: Free play, AutoPlay (drift-compensated), and chord-aware Guide Mode (white highlights on virtual UI & hardware MIDI).
- **Native UI & persistence**: Sokol-gfx + SDL3/SDL3_ttf dark studio UI, native file/folder dialogs (`nativefiledialog-extended`), and persistent user settings.

## Build & Run

Requires Zig `0.17+`, `naga`, `SDL3`, `SDL3_ttf`, `libarchive` (plus `alsa` and `dbus-1` on Linux; `portaudio` + `spirv-cross` on Windows/macOS).

```bash
# Release build (recommended for 1-period low-latency audio)
zig build run -Doptimize=ReleaseFast

# Convert an Ableton Live project (.zip, folder, or .als) to a standard UniPack .zip
zig build run -Doptimize=ReleaseFast -- --convert "Project.zip" "output_unipack.zip"

# Tests
zig build test
```

### Shortcuts

- `O`: Open `.zip` / `.uni` UniPack
- `Shift+O`: Open UniPack folder
- `Space`: Toggle AutoPlay
- `Tab`: Open Settings

## License

[GPLv3](LICENSE). See [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) for bundled and linked dependencies.
