#ifndef KC_INTERNAL_H
#define KC_INTERNAL_H

#include "keycadence.h"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>

#define KC_VOICES 24
#define KC_RING_SIZE 64 // power of two
#define KC_MAX_VARIATIONS 8

typedef struct {
    const float *data;
    uint32_t length;
    float position; // -1 .. 1 across the keyboard
    float gain;
    float rate;
    double delay_seconds;
    uint64_t host_time;
    bool effect, preview;
} kc_trigger;

// Single producer, single consumer.
typedef struct {
    _Atomic uint32_t write;
    _Atomic uint32_t read;
    kc_trigger items[KC_RING_SIZE];
} kc_ring;

typedef struct {
    const float *data; // NULL when free
    uint32_t length;
    double pos, step, itd_l, itd_r;
    float gain, gain_l, gain_r, shadow_l, shadow_r, state_l, state_r;
    bool effect, preview;
} kc_voice;

typedef struct { float b0, b1, b2, a1, a2; } biquad;
typedef struct { biquad high, low; bool active; } tone_coeffs;

typedef struct {
    _Atomic uint64_t count;
    double last_ms, min_ms, max_ms, sum_ms;
} kc_latency;

struct kc_engine {
    // Settings (any thread)
    _Atomic bool enabled, pan, spatial, pitch_variation, ignore_rapid, mute_modifiers, mouse_sounds, return_ding;
    _Atomic int profile, profile_count;
    _Atomic float volume, effects_volume, quiet_gain;

    // Sound pack (immutable after load)
    void *pack_map;
    size_t pack_size;
    const float *pack_samples;
    const void *pack_table;
    uint32_t pack_rate, pack_variations;

    // Producer -> audio thread
    kc_ring key_ring, ui_ring;

    // Audio thread only
    kc_voice voices[KC_VOICES];
    float tone_state[2][4];
    float scratch[4096];
    kc_latency latency;

    // Tone: written under tone_lock, published by slot flip. The audio thread
    // reads the active slot; the UI only writes the inactive one.
    tone_coeffs tone[2];
    _Atomic int tone_slot;
    pthread_mutex_t tone_lock;
    float tone_x, tone_y;

    // Output, owned by the control thread
    pthread_t control;
    dispatch_semaphore_t wake;
    AudioUnit unit;
    AudioObjectID listening_device;
    bool running;
    double device_rate, device_latency_ms, last_cold_start_ms;
    uint32_t buffer_frames;
    uint64_t cold_starts;
    _Atomic uint32_t requested_device, requested_buffer_frames;
    _Atomic bool want_start, needs_rebuild, shutdown, running_flag;
    _Atomic uint64_t last_activity;

    // Key tap thread
    pthread_t tap_thread;
    CFRunLoopRef tap_loop;
    CFMachPortRef tap_port;
    _Atomic bool tap_running;
    bool tap_thread_started;
    uint32_t rng, ui_rng;
    uint8_t last_variation[KC_CLASS_COUNT * 2];
    bool key_held[128];
    bool key_ignored[128];
    uint64_t last_down_time;
    _Atomic uint64_t key_count;
};

bool kc_ring_push(kc_ring *ring, const kc_trigger *t);
bool kc_lookup_sound(const kc_engine *e, int profile, int klass, int up, uint32_t variation,
                     const float **data, uint32_t *length);
void kc_note_activity(kc_engine *e, uint64_t now);
void kc_tap_stop(kc_engine *e);

#endif
