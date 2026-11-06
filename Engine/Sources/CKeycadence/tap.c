// Key capture: a listen-only event tap on its own high-priority thread.
//
// Listen-only means events cannot be modified or delayed by this app, and only
// the keycode is read: it selects a sound and a stereo position, then is dropped.
// Nothing is stored or logged. macOS withholds key events during secure input
// (password fields), so those keystrokes never reach this code.
#include "internal.h"

#include <CoreGraphics/CoreGraphics.h>
#include <mach/mach_time.h>
#include <pthread.h>

#define KC_RAPID_SECONDS 0.030

static mach_timebase_info_data_t g_tb;

static inline uint32_t next_random(uint32_t *s) {
    uint32_t x = *s;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    *s = x;
    return x;
}

static inline float random_unit(uint32_t *s) {
    return (float)(next_random(s) >> 8) * (1.0f / 16777216.0f); // 0..1
}

static void trigger_sound(kc_engine *e, int profile, int klass, int up, float position, float gain,
                          bool effect, uint64_t now) {
    uint32_t variations = e->pack_variations ? e->pack_variations : 1;
    // Never the same sample twice in a row: repeats are what sound artificial.
    size_t slot = (size_t)klass * 2 + (size_t)up;
    uint32_t v = next_random(&e->rng) % variations;
    if (variations > 1 && v == e->last_variation[slot]) v = (v + 1) % variations;
    e->last_variation[slot] = (uint8_t)v;

    const float *data;
    uint32_t length;
    if (!kc_lookup_sound(e, profile, klass, up, v, &data, &length) &&
        !kc_lookup_sound(e, profile, klass, up, 0, &data, &length)) {
        return;
    }

    float rate = 1.0f, g = gain;
    if (atomic_load_explicit(&e->pitch_variation, memory_order_relaxed)) {
        rate = 0.965f + 0.07f * random_unit(&e->rng);
        g *= 0.86f + 0.14f * random_unit(&e->rng);
    }
    kc_trigger t = {.data = data, .length = length, .position = position, .gain = g, .rate = rate,
                    .delay_seconds = 0.0, .host_time = now, .effect = effect};
    kc_ring_push(&e->key_ring, &t);
}

void kc_engine_key_event(kc_engine *e, uint16_t code, bool down) {
    if (code >= 128) return;
    uint64_t now = mach_absolute_time();
    if (down) {
        atomic_fetch_add_explicit(&e->key_count, 1, memory_order_relaxed);
    }
    if (!atomic_load_explicit(&e->enabled, memory_order_relaxed)) return;
    if (atomic_load_explicit(&e->quiet_gain, memory_order_relaxed) <= 0.0f) return; // silent: leave audio off

    kc_key_class klass = kc_key_class_for_keycode(code);
    if (klass == KC_CLASS_MODIFIER && atomic_load_explicit(&e->mute_modifiers, memory_order_relaxed)) return;

    if (down) {
        if (atomic_load_explicit(&e->ignore_rapid, memory_order_relaxed)) {
            if (!g_tb.denom) mach_timebase_info(&g_tb);
            double dt = (double)(now - e->last_down_time) * g_tb.numer / g_tb.denom * 1e-9;
            if (dt < KC_RAPID_SECONDS) {
                e->key_ignored[code] = true; // the matching key-up stays silent too
                return;
            }
        }
        e->last_down_time = now;
        e->key_ignored[code] = false;
    } else if (e->key_ignored[code]) {
        e->key_ignored[code] = false;
        return;
    }

    int profile = atomic_load_explicit(&e->profile, memory_order_relaxed);
    float position = kc_key_position_for_keycode(code);
    trigger_sound(e, profile, (int)klass, down ? 0 : 1, position, 1.0f, false, now);
    if (down && klass == KC_CLASS_RETURN && atomic_load_explicit(&e->return_ding, memory_order_relaxed)) {
        int bank = atomic_load_explicit(&e->profile_count, memory_order_relaxed);
        trigger_sound(e, bank, KC_EFFECT_DING, 0, position, 1.0f, true, now);
    }
    kc_note_activity(e, now);
}

static void handle_modifier(kc_engine *e, uint16_t code, CGEventFlags flags) {
    if (code >= 128) return;
    CGEventFlags family = 0;
    switch (code) {
    case 0x38: case 0x3C: family = kCGEventFlagMaskShift; break;
    case 0x3B: case 0x3E: family = kCGEventFlagMaskControl; break;
    case 0x3A: case 0x3D: family = kCGEventFlagMaskAlternate; break;
    case 0x36: case 0x37: family = kCGEventFlagMaskCommand; break;
    case 0x3F: family = kCGEventFlagMaskSecondaryFn; break;
    case 0x39:
        // Caps lock reports a state change, not press and release.
        kc_engine_key_event(e, code, true);
        kc_engine_key_event(e, code, false);
        return;
    default:
        return;
    }
    // Toggle per key so left and right shift are tracked apart, but trust the
    // flags when the family is fully released: a missed event can't stick a key.
    bool down = (flags & family) != 0 && !e->key_held[code];
    e->key_held[code] = down;
    kc_engine_key_event(e, code, down);
}

static void handle_mouse(kc_engine *e, bool down) {
    if (!atomic_load_explicit(&e->mouse_sounds, memory_order_relaxed)) return;
    if (!atomic_load_explicit(&e->enabled, memory_order_relaxed)) return;
    if (atomic_load_explicit(&e->quiet_gain, memory_order_relaxed) <= 0.0f) return;
    uint64_t now = mach_absolute_time();
    int bank = atomic_load_explicit(&e->profile_count, memory_order_relaxed);
    trigger_sound(e, bank, KC_EFFECT_MOUSE, down ? 0 : 1, 0.25f, 1.0f, true, now);
    kc_note_activity(e, now);
}

static CGEventRef tap_callback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *ref) {
    kc_engine *e = ref;
    switch (type) {
    case kCGEventKeyDown:
        // Auto-repeat: a held mechanical key does not re-actuate.
        if (!CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat)) {
            kc_engine_key_event(e, (uint16_t)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode), true);
        }
        break;
    case kCGEventKeyUp:
        kc_engine_key_event(e, (uint16_t)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode), false);
        break;
    case kCGEventFlagsChanged:
        handle_modifier(e, (uint16_t)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode),
                        CGEventGetFlags(event));
        break;
    case kCGEventLeftMouseDown: case kCGEventRightMouseDown: case kCGEventOtherMouseDown:
        handle_mouse(e, true);
        break;
    case kCGEventLeftMouseUp: case kCGEventRightMouseUp: case kCGEventOtherMouseUp:
        handle_mouse(e, false);
        break;
    case kCGEventTapDisabledByTimeout: case kCGEventTapDisabledByUserInput:
        if (e->tap_port) CGEventTapEnable(e->tap_port, true);
        break;
    default:
        break;
    }
    return event;
}

typedef struct {
    kc_engine *engine;
    dispatch_semaphore_t ready;
    bool ok;
} tap_start;

static void *tap_thread(void *arg) {
    tap_start *s = arg;
    kc_engine *e = s->engine;
    pthread_setname_np("keycadence.tap");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) |
                       CGEventMaskBit(kCGEventFlagsChanged) | CGEventMaskBit(kCGEventLeftMouseDown) |
                       CGEventMaskBit(kCGEventLeftMouseUp) | CGEventMaskBit(kCGEventRightMouseDown) |
                       CGEventMaskBit(kCGEventRightMouseUp) | CGEventMaskBit(kCGEventOtherMouseDown) |
                       CGEventMaskBit(kCGEventOtherMouseUp);
    CFMachPortRef port = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly,
                                          mask, tap_callback, e);
    if (!port) {
        s->ok = false;
        dispatch_semaphore_signal(s->ready);
        return NULL;
    }
    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(NULL, port, 0);
    e->tap_port = port;
    e->tap_loop = CFRunLoopGetCurrent();
    CFRunLoopAddSource(e->tap_loop, source, kCFRunLoopCommonModes);
    CGEventTapEnable(port, true);
    atomic_store(&e->tap_running, true);
    s->ok = true;
    dispatch_semaphore_signal(s->ready);

    CFRunLoopRun();

    atomic_store(&e->tap_running, false);
    CGEventTapEnable(port, false);
    CFRunLoopSourceInvalidate(source);
    CFRelease(source);
    CFMachPortInvalidate(port);
    CFRelease(port);
    e->tap_port = NULL;
    return NULL;
}

bool kc_tap_has_permission(void) { return CGPreflightListenEventAccess(); }
bool kc_tap_request_permission(void) { return CGRequestListenEventAccess(); }
bool kc_tap_is_running(const kc_engine *e) { return atomic_load(&e->tap_running); }

bool kc_tap_start(kc_engine *e) {
    if (atomic_load(&e->tap_running)) return true;
    if (e->tap_thread_started) {
        pthread_join(e->tap_thread, NULL);
        e->tap_thread_started = false;
    }
    tap_start s = {.engine = e, .ready = dispatch_semaphore_create(0), .ok = false};
    if (pthread_create(&e->tap_thread, NULL, tap_thread, &s) != 0) return false;
    e->tap_thread_started = true;
    dispatch_semaphore_wait(s.ready, DISPATCH_TIME_FOREVER);
    return s.ok;
}

void kc_tap_stop(kc_engine *e) {
    if (!e->tap_thread_started) return;
    if (e->tap_loop && atomic_load(&e->tap_running)) CFRunLoopStop(e->tap_loop);
    pthread_join(e->tap_thread, NULL);
    e->tap_thread_started = false;
}
