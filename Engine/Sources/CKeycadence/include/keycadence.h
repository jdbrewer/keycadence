// Keycadence engine: the real-time path from key event to audio output.
//
// Everything on the key-tap and audio threads lives in C so that no Swift
// runtime work (ARC, exclusivity checks, allocation) can run on them.
#ifndef KEYCADENCE_H
#define KEYCADENCE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct kc_engine kc_engine;

typedef enum {
    KC_CLASS_ALPHA = 0,
    KC_CLASS_SPACE = 1,
    KC_CLASS_RETURN = 2,
    KC_CLASS_BACKSPACE = 3,
    KC_CLASS_MODIFIER = 4,
    KC_CLASS_COUNT = 5,
} kc_key_class;

// Sounds in the shared effects bank (the last profile in a pack).
typedef enum {
    KC_EFFECT_MOUSE = 0, // down + up variants
    KC_EFFECT_DING = 1,  // down only
} kc_effect;

typedef struct {
    uint64_t count;
    double last_ms; // key event reached us -> first sample at the device
    double min_ms;
    double max_ms;
    double mean_ms;
    double device_ms; // extra latency the output device itself reports
    double sample_rate;
    uint32_t buffer_frames;
    uint64_t cold_starts;
    double last_cold_start_ms;
    bool running;
} kc_stats;

kc_engine *kc_engine_create(void);
void kc_engine_destroy(kc_engine *engine);

// Maps a sound pack read-only. Returns false if it is missing or malformed.
bool kc_engine_load_pack(kc_engine *engine, const char *path);
int kc_engine_profile_count(const kc_engine *engine);

// Settings. Safe from any thread; they take effect on the next audio block.
void kc_engine_set_enabled(kc_engine *engine, bool enabled);
void kc_engine_set_profile(kc_engine *engine, int profile);
void kc_engine_set_volume(kc_engine *engine, float volume);
void kc_engine_set_effects_volume(kc_engine *engine, float volume);
void kc_engine_set_quiet_gain(kc_engine *engine, float gain); // 1 = not quiet
void kc_engine_set_pan(kc_engine *engine, bool on);
void kc_engine_set_spatial(kc_engine *engine, bool on);
void kc_engine_set_pitch_variation(kc_engine *engine, bool on);
void kc_engine_set_ignore_rapid(kc_engine *engine, bool on);
void kc_engine_set_mute_modifiers(kc_engine *engine, bool on);
void kc_engine_set_mouse_sounds(kc_engine *engine, bool on);
void kc_engine_set_return_ding(kc_engine *engine, bool on);
// Both axes in [-1, 1]: x is dark to bright, y is thin to full.
void kc_engine_set_tone(kc_engine *engine, float x, float y);
// 0 follows the system default output.
void kc_engine_set_output_device(kc_engine *engine, uint32_t device_id);
// Output buffer in frames, within what the device allows. Smaller is quicker, and costs CPU.
void kc_engine_set_buffer_frames(kc_engine *engine, uint32_t frames);

// Plays a sound regardless of the enabled and quiet state (UI only).
void kc_engine_preview_profile(kc_engine *engine, int profile);
void kc_engine_preview_effect(kc_engine *engine, kc_effect effect);

// Key capture. A listen-only event tap needs the Input Monitoring permission.
bool kc_tap_has_permission(void);
bool kc_tap_request_permission(void);
// False if the tap could not be created (normally: permission not granted).
bool kc_tap_start(kc_engine *engine);
bool kc_tap_is_running(const kc_engine *engine);

// Key-down count since launch. Never records which keys were pressed.
uint64_t kc_engine_key_count(const kc_engine *engine);
void kc_engine_get_stats(const kc_engine *engine, kc_stats *out);

// --- Used by tests and kc-bench ---

// Injects a key event as the tap callback would.
void kc_engine_key_event(kc_engine *engine, uint16_t keycode, bool down);
// Runs the mixer without an audio device.
void kc_engine_render_offline(kc_engine *engine, float *left, float *right,
                              uint32_t frames, double sample_rate);
bool kc_engine_is_running(const kc_engine *engine);

kc_key_class kc_key_class_for_keycode(uint16_t keycode);
float kc_key_position_for_keycode(uint16_t keycode); // -1 left .. 1 right

#ifdef __cplusplus
}
#endif
#endif
