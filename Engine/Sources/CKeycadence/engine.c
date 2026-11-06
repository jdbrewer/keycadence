// Mixer, sound pack loader and CoreAudio output.
//
// Threads:
//   key tap  -> pushes triggers into a lock-free ring (never blocks)
//   UI       -> settings via atomics, previews through a second ring
//   audio    -> drains rings, mixes voices (no locks, no allocation, no syscalls)
//   control  -> starts and stops the output unit, follows device changes
//
// The output is stopped after a short idle period: a running CoreAudio output
// keeps the Mac from idle-sleeping and costs power, so it only runs while typing.
#include "internal.h"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define KC_TARGET_BUFFER_FRAMES 128
#define KC_IDLE_STOP_SECONDS 20.0
#define KC_STALE_TRIGGER_SECONDS 0.35
#define KC_MAX_ITD_SECONDS 0.00045
#define KC_MAX_BLOCK 4096

static mach_timebase_info_data_t g_timebase;

static inline double ticks_to_seconds(uint64_t t) {
    return (double)t * g_timebase.numer / g_timebase.denom * 1e-9;
}

// ---------------------------------------------------------------------------
// Rings
// ---------------------------------------------------------------------------

bool kc_ring_push(kc_ring *ring, const kc_trigger *t) {
    uint32_t w = atomic_load_explicit(&ring->write, memory_order_relaxed);
    uint32_t r = atomic_load_explicit(&ring->read, memory_order_acquire);
    if (w - r >= KC_RING_SIZE) return false;
    ring->items[w & (KC_RING_SIZE - 1)] = *t;
    atomic_store_explicit(&ring->write, w + 1, memory_order_release);
    return true;
}

static inline bool ring_pop(kc_ring *ring, kc_trigger *t) {
    uint32_t r = atomic_load_explicit(&ring->read, memory_order_relaxed);
    uint32_t w = atomic_load_explicit(&ring->write, memory_order_acquire);
    if (r == w) return false;
    *t = ring->items[r & (KC_RING_SIZE - 1)];
    atomic_store_explicit(&ring->read, r + 1, memory_order_release);
    return true;
}

// ---------------------------------------------------------------------------
// Sound pack
// ---------------------------------------------------------------------------
//
// Layout (little endian):
//   char magic[4] = "KCPK"; u32 version; u32 sample_rate; u32 profiles (incl. effects bank)
//   u32 variations; u32 data_offset;
//   entries: [profile][class][direction][variation] { u32 offset_in_samples, u32 length }
//   f32 samples[]

typedef struct {
    char magic[4];
    uint32_t version, sample_rate, profiles, variations, data_offset;
} pack_header;

typedef struct { uint32_t offset, length; } pack_entry;

bool kc_engine_load_pack(kc_engine *e, const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(pack_header)) {
        close(fd);
        return false;
    }
    void *map = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (map == MAP_FAILED) return false;

    const pack_header *h = map;
    if (memcmp(h->magic, "KCPK", 4) != 0 || h->version != 1 || h->profiles < 2 ||
        h->variations == 0 || h->variations > KC_MAX_VARIATIONS ||
        h->data_offset >= (uint64_t)st.st_size) {
        munmap(map, (size_t)st.st_size);
        return false;
    }
    uint64_t table_bytes = (uint64_t)h->profiles * KC_CLASS_COUNT * 2 * h->variations * sizeof(pack_entry);
    if (sizeof(pack_header) + table_bytes > h->data_offset) {
        munmap(map, (size_t)st.st_size);
        return false;
    }
    uint64_t total_samples = ((uint64_t)st.st_size - h->data_offset) / sizeof(float);
    const pack_entry *table = (const pack_entry *)(h + 1);
    for (uint64_t i = 0; i < table_bytes / sizeof(pack_entry); i++) {
        if ((uint64_t)table[i].offset + table[i].length > total_samples) {
            munmap(map, (size_t)st.st_size);
            return false;
        }
    }

    e->pack_map = map;
    e->pack_size = (size_t)st.st_size;
    e->pack_samples = (const float *)((const char *)map + h->data_offset);
    e->pack_table = table;
    e->pack_rate = h->sample_rate;
    e->pack_variations = h->variations;
    atomic_store(&e->profile_count, (int)h->profiles - 1);

    // Sounds must be resident before the audio thread touches them: a page
    // fault there would be an audible glitch. Pack is small (see tools/).
    mlock(map, (size_t)st.st_size);
    return true;
}

int kc_engine_profile_count(const kc_engine *e) { return atomic_load(&e->profile_count); }

bool kc_lookup_sound(const kc_engine *e, int profile, int klass, int up, uint32_t variation,
                     const float **data, uint32_t *length) {
    if (!e->pack_table) return false;
    size_t v = e->pack_variations;
    size_t profiles = (size_t)atomic_load_explicit(&e->profile_count, memory_order_relaxed) + 1;
    if (profile < 0 || (size_t)profile >= profiles) return false;
    size_t idx = (((size_t)profile * KC_CLASS_COUNT + (size_t)klass) * 2 + (size_t)up) * v + variation % v;
    const pack_entry *entry = (const pack_entry *)e->pack_table + idx;
    if (entry->length == 0) return false;
    *data = e->pack_samples + entry->offset;
    *length = entry->length;
    return true;
}

// ---------------------------------------------------------------------------
// Tone (master EQ): two shelves, coefficients published by atomic slot flip.
// ---------------------------------------------------------------------------

static void shelf(biquad *b, double rate, double freq, double gain_db, bool high) {
    double A = pow(10.0, gain_db / 40.0);
    double w = 2.0 * M_PI * freq / rate;
    double c = cos(w), s = sin(w);
    double alpha = s / 2.0 * sqrt(2.0); // Q = 0.5 shelf slope
    double beta = 2.0 * sqrt(A) * alpha;
    double b0, b1, b2, a0, a1, a2;
    if (high) {
        b0 = A * ((A + 1) + (A - 1) * c + beta);
        b1 = -2 * A * ((A - 1) + (A + 1) * c);
        b2 = A * ((A + 1) + (A - 1) * c - beta);
        a0 = (A + 1) - (A - 1) * c + beta;
        a1 = 2 * ((A - 1) - (A + 1) * c);
        a2 = (A + 1) - (A - 1) * c - beta;
    } else {
        b0 = A * ((A + 1) - (A - 1) * c + beta);
        b1 = 2 * A * ((A - 1) - (A + 1) * c);
        b2 = A * ((A + 1) - (A - 1) * c - beta);
        a0 = (A + 1) + (A - 1) * c + beta;
        a1 = -2 * ((A - 1) + (A + 1) * c);
        a2 = (A + 1) + (A - 1) * c - beta;
    }
    b->b0 = (float)(b0 / a0);
    b->b1 = (float)(b1 / a0);
    b->b2 = (float)(b2 / a0);
    b->a1 = (float)(a1 / a0);
    b->a2 = (float)(a2 / a0);
}

static void publish_tone(kc_engine *e, double rate) {
    pthread_mutex_lock(&e->tone_lock);
    float x = e->tone_x, y = e->tone_y;
    int next = 1 - atomic_load(&e->tone_slot);
    tone_coeffs *t = &e->tone[next];
    t->active = fabsf(x) > 0.01f || fabsf(y) > 0.01f;
    shelf(&t->high, rate, 3200.0, (double)x * 9.0, true);
    shelf(&t->low, rate, 280.0, (double)y * 9.0, false);
    atomic_store_explicit(&e->tone_slot, next, memory_order_release);
    pthread_mutex_unlock(&e->tone_lock);
}

void kc_engine_set_tone(kc_engine *e, float x, float y) {
    pthread_mutex_lock(&e->tone_lock);
    e->tone_x = x;
    e->tone_y = y;
    pthread_mutex_unlock(&e->tone_lock);
    publish_tone(e, e->device_rate > 0 ? e->device_rate : 48000.0);
}

// ---------------------------------------------------------------------------
// Mixer (audio thread)
// ---------------------------------------------------------------------------

static inline float read_sample(const float *data, uint32_t length, double pos) {
    if (pos < 0.0) return 0.0f;
    uint32_t i = (uint32_t)pos;
    if (i >= length) return 0.0f;
    float frac = (float)(pos - i);
    float a = data[i];
    float b = (i + 1 < length) ? data[i + 1] : 0.0f;
    return a + (b - a) * frac;
}

static void start_voice(kc_engine *e, const kc_trigger *t, uint64_t output_host_time, double rate) {
    uint64_t now = mach_absolute_time();
    if (t->host_time && now > t->host_time && ticks_to_seconds(now - t->host_time) > KC_STALE_TRIGGER_SECONDS) {
        return; // the output took too long to start: a late click is worse than none
    }

    // Reuse a free voice, or steal the one closest to finishing.
    kc_voice *v = NULL;
    double best = -1.0;
    for (int i = 0; i < KC_VOICES; i++) {
        kc_voice *c = &e->voices[i];
        if (!c->data) { v = c; break; }
        double progress = c->pos / c->length;
        if (progress > best) { best = progress; v = c; }
    }

    bool pan = atomic_load_explicit(&e->pan, memory_order_relaxed);
    bool spatial = atomic_load_explicit(&e->spatial, memory_order_relaxed);
    float x = t->position;
    float px = pan ? x * 0.7f : 0.0f;
    float angle = (px + 1.0f) * (float)M_PI_4;

    v->data = t->data;
    v->length = t->length;
    v->step = (double)t->rate * e->pack_rate / rate;
    v->pos = -t->delay_seconds * e->pack_rate;
    v->gain = t->gain;
    v->effect = t->effect;
    v->preview = t->preview;
    v->gain_l = cosf(angle) * (float)M_SQRT2;
    v->gain_r = sinf(angle) * (float)M_SQRT2;
    v->shadow_l = v->shadow_r = 0.0f;
    v->state_l = v->state_r = 0.0f;
    v->itd_l = v->itd_r = 0.0;
    if (spatial) {
        // Interaural time difference and head shadow: the far ear hears the key
        // slightly later and duller. This is what places it outside the head.
        double itd = fabsf(x) * KC_MAX_ITD_SECONDS * e->pack_rate;
        float shadow = fabsf(x) * 0.55f;
        if (x > 0) { v->itd_l = itd; v->shadow_l = shadow; }
        else       { v->itd_r = itd; v->shadow_r = shadow; }
    }

    if (t->host_time && output_host_time > t->host_time && t->delay_seconds == 0.0) {
        double ms = ticks_to_seconds(output_host_time - t->host_time) * 1000.0;
        kc_latency *s = &e->latency;
        uint64_t n = atomic_load_explicit(&s->count, memory_order_relaxed) + 1;
        s->last_ms = ms;
        s->sum_ms += ms;
        if (n == 1 || ms < s->min_ms) s->min_ms = ms;
        if (ms > s->max_ms) s->max_ms = ms;
        atomic_store_explicit(&s->count, n, memory_order_release);
    }
}

// Mixes one block. Runs on the audio thread: must never block or allocate.
static bool mix_block(kc_engine *e, float *restrict left, float *restrict right, uint32_t frames,
                      uint64_t output_host_time, double rate) {
    kc_trigger t;
    while (ring_pop(&e->key_ring, &t)) start_voice(e, &t, output_host_time, rate);
    while (ring_pop(&e->ui_ring, &t)) start_voice(e, &t, output_host_time, rate);

    bool any = false;
    float master = atomic_load_explicit(&e->volume, memory_order_relaxed);
    float effects = atomic_load_explicit(&e->effects_volume, memory_order_relaxed);
    float quiet = atomic_load_explicit(&e->quiet_gain, memory_order_relaxed);

    memset(left, 0, frames * sizeof(float));
    memset(right, 0, frames * sizeof(float));

    for (int n = 0; n < KC_VOICES; n++) {
        kc_voice *v = &e->voices[n];
        if (!v->data) continue;
        any = true;
        float g = v->gain * master * (v->effect ? effects : 1.0f) * (v->preview ? 1.0f : quiet);
        float gl = g * v->gain_l, gr = g * v->gain_r;
        const float *data = v->data;
        uint32_t len = v->length;
        double pos = v->pos, step = v->step, il = v->itd_l, ir = v->itd_r;
        float sl = v->shadow_l, sr = v->shadow_r, zl = v->state_l, zr = v->state_r;
        for (uint32_t i = 0; i < frames; i++) {
            float a = read_sample(data, len, pos - il);
            float b = read_sample(data, len, pos - ir);
            zl += (a - zl) * (1.0f - sl);
            zr += (b - zr) * (1.0f - sr);
            left[i] += zl * gl;
            right[i] += zr * gr;
            pos += step;
        }
        v->pos = pos;
        v->state_l = zl;
        v->state_r = zr;
        if (pos - (il > ir ? il : ir) >= (double)len) v->data = NULL;
    }

    tone_coeffs *tone = &e->tone[atomic_load_explicit(&e->tone_slot, memory_order_acquire)];
    if (any && tone->active) {
        biquad *bq[2] = {&tone->high, &tone->low};
        for (int f = 0; f < 2; f++) {
            const biquad *c = bq[f];
            float *s = e->tone_state[f];
            for (int ch = 0; ch < 2; ch++) {
                float *buf = ch ? right : left;
                float z1 = s[ch * 2], z2 = s[ch * 2 + 1];
                for (uint32_t i = 0; i < frames; i++) {
                    float in = buf[i];
                    float out = c->b0 * in + z1;
                    z1 = c->b1 * in - c->a1 * out + z2;
                    z2 = c->b2 * in - c->a2 * out;
                    buf[i] = out;
                }
                s[ch * 2] = z1;
                s[ch * 2 + 1] = z2;
            }
        }
    }

    // Soft limiter: fast mashing must saturate gently rather than click.
    if (any) {
        for (uint32_t i = 0; i < frames; i++) {
            float l = left[i], r = right[i];
            if (fabsf(l) > 0.8f) l = copysignf(0.8f + 0.2f * tanhf((fabsf(l) - 0.8f) / 0.2f), l);
            if (fabsf(r) > 0.8f) r = copysignf(0.8f + 0.2f * tanhf((fabsf(r) - 0.8f) / 0.2f), r);
            left[i] = l;
            right[i] = r;
        }
    }
    return any;
}

void kc_engine_render_offline(kc_engine *e, float *left, float *right, uint32_t frames, double rate) {
    if (rate != e->device_rate) {
        e->device_rate = rate;
        publish_tone(e, rate);
    }
    uint32_t done = 0;
    while (done < frames) {
        uint32_t n = frames - done > 256 ? 256 : frames - done;
        mix_block(e, left + done, right + done, n, 0, rate);
        done += n;
    }
}

static OSStatus render_callback(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                                UInt32 bus, UInt32 frames, AudioBufferList *io) {
    kc_engine *e = ref;
    float *l = io->mBuffers[0].mData;
    float *r = io->mNumberBuffers > 1 ? io->mBuffers[1].mData : e->scratch;
    if (frames > KC_MAX_BLOCK) frames = KC_MAX_BLOCK;
    uint64_t host = (ts->mFlags & kAudioTimeStampHostTimeValid) ? ts->mHostTime : mach_absolute_time();
    bool sound = mix_block(e, l, r, frames, host, e->device_rate);
    if (!sound) *flags |= kAudioUnitRenderAction_OutputIsSilence;
    return noErr;
}

// ---------------------------------------------------------------------------
// Output device (control thread)
// ---------------------------------------------------------------------------

static OSStatus device_changed(AudioObjectID obj, UInt32 n, const AudioObjectPropertyAddress *a, void *ref) {
    kc_engine *e = ref;
    atomic_store(&e->needs_rebuild, true);
    dispatch_semaphore_signal(e->wake);
    return noErr;
}

static const AudioObjectPropertyAddress kDefaultOutputAddr = {
    kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
static const AudioObjectPropertyAddress kRateAddr = {
    kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
static const AudioObjectPropertyAddress kAliveAddr = {
    kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};

static void teardown_output(kc_engine *e) {
    if (e->unit) {
        if (e->running) AudioOutputUnitStop(e->unit);
        AudioUnitUninitialize(e->unit);
        AudioComponentInstanceDispose(e->unit);
        e->unit = NULL;
    }
    atomic_store(&e->running_flag, false);
    e->running = false;
    if (e->listening_device) {
        AudioObjectRemovePropertyListener(e->listening_device, &kRateAddr, device_changed, e);
        AudioObjectRemovePropertyListener(e->listening_device, &kAliveAddr, device_changed, e);
        e->listening_device = 0;
    }
}

static double device_latency_ms(AudioDeviceID dev, double rate) {
    UInt32 total = 0, value = 0, size = sizeof(value);
    AudioObjectPropertyAddress a = {kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput,
                                    kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, &value) == noErr) total += value;
    a.mSelector = kAudioDevicePropertySafetyOffset;
    size = sizeof(value);
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, &value) == noErr) total += value;
    a.mSelector = kAudioDevicePropertyStreams;
    AudioStreamID stream = 0;
    size = sizeof(stream);
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, &stream) == noErr && stream) {
        AudioObjectPropertyAddress s = {kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain};
        size = sizeof(value);
        if (AudioObjectGetPropertyData(stream, &s, 0, NULL, &size, &value) == noErr) total += value;
    }
    return total / rate * 1000.0;
}

static bool build_output(kc_engine *e) {
    AudioDeviceID dev = atomic_load(&e->requested_device);
    UInt32 size = sizeof(dev);
    if (dev == 0 &&
        AudioObjectGetPropertyData(kAudioObjectSystemObject, &kDefaultOutputAddr, 0, NULL, &size, &dev) != noErr) {
        return false;
    }
    if (dev == kAudioObjectUnknown) return false;

    Float64 rate = 48000.0;
    size = sizeof(rate);
    AudioObjectGetPropertyData(dev, &kRateAddr, 0, NULL, &size, &rate);

    AudioComponentDescription desc = {kAudioUnitType_Output, kAudioUnitSubType_HALOutput,
                                      kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    AudioUnit unit = NULL;
    if (!comp || AudioComponentInstanceNew(comp, &unit) != noErr) return false;

    UInt32 on = 1, off = 0;
    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &on, sizeof(on));
    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &off, sizeof(off));
    OSStatus st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &dev, sizeof(dev));

    // Ask for the smallest sensible hardware buffer, within what the device allows.
    AudioValueRange range = {0, 0};
    size = sizeof(range);
    AudioObjectPropertyAddress ra = {kAudioDevicePropertyBufferFrameSizeRange, kAudioObjectPropertyScopeOutput,
                                     kAudioObjectPropertyElementMain};
    UInt32 buffer = atomic_load(&e->requested_buffer_frames);
    if (AudioObjectGetPropertyData(dev, &ra, 0, NULL, &size, &range) == noErr) {
        if (buffer < range.mMinimum) buffer = (UInt32)range.mMinimum;
        if (buffer > range.mMaximum) buffer = (UInt32)range.mMaximum;
    }
    AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &buffer, sizeof(buffer));
    UInt32 actual = buffer;
    size = sizeof(actual);
    AudioUnitGetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &actual, &size);

    UInt32 maxFrames = KC_MAX_BLOCK;
    AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames,
                         sizeof(maxFrames));

    AudioStreamBasicDescription fmt = {0};
    fmt.mSampleRate = rate;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
    fmt.mBytesPerPacket = fmt.mBytesPerFrame = sizeof(float);
    fmt.mFramesPerPacket = 1;
    fmt.mChannelsPerFrame = 2;
    fmt.mBitsPerChannel = 32;
    if (st == noErr) {
        st = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));
    }

    AURenderCallbackStruct cb = {render_callback, e};
    if (st == noErr) {
        st = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof(cb));
    }
    if (st == noErr) st = AudioUnitInitialize(unit);
    if (st != noErr) {
        AudioComponentInstanceDispose(unit);
        return false;
    }

    e->unit = unit;
    e->device_rate = rate;
    e->buffer_frames = actual;
    e->device_latency_ms = device_latency_ms(dev, rate);
    publish_tone(e, rate);

    AudioObjectAddPropertyListener(dev, &kRateAddr, device_changed, e);
    AudioObjectAddPropertyListener(dev, &kAliveAddr, device_changed, e);
    e->listening_device = dev;
    return true;
}

static void *control_thread(void *arg) {
    kc_engine *e = arg;
    pthread_setname_np("keycadence.control");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

    for (;;) {
        // Only tick while audio is running; otherwise sleep until woken.
        dispatch_time_t deadline = e->running ? dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC) : DISPATCH_TIME_FOREVER;
        dispatch_semaphore_wait(e->wake, deadline);
        if (atomic_load(&e->shutdown)) break;

        if (atomic_exchange(&e->needs_rebuild, false)) {
            bool was_running = e->running;
            teardown_output(e);
            if (was_running) atomic_store(&e->want_start, true);
        }

        if (atomic_exchange(&e->want_start, false) && !e->running) {
            uint64_t t0 = mach_absolute_time();
            if (e->unit || build_output(e)) {
                if (AudioOutputUnitStart(e->unit) == noErr) {
                    e->running = true;
                    atomic_store(&e->running_flag, true);
                    e->cold_starts++;
                    e->last_cold_start_ms = ticks_to_seconds(mach_absolute_time() - t0) * 1000.0;
                }
            }
        }

        // Keep the unit built while stopped: restarting it is much faster than
        // creating it, and the first key after a pause is the one people notice.
        if (!e->unit) build_output(e);

        if (e->running) {
            uint64_t last = atomic_load_explicit(&e->last_activity, memory_order_relaxed);
            if (ticks_to_seconds(mach_absolute_time() - last) > KC_IDLE_STOP_SECONDS) {
                AudioOutputUnitStop(e->unit);
                e->running = false;
                atomic_store(&e->running_flag, false);
            }
        }
    }
    teardown_output(e);
    return NULL;
}

void kc_note_activity(kc_engine *e, uint64_t now) {
    atomic_store_explicit(&e->last_activity, now, memory_order_relaxed);
    if (!atomic_load_explicit(&e->running_flag, memory_order_relaxed) &&
        !atomic_exchange_explicit(&e->want_start, true, memory_order_relaxed)) {
        dispatch_semaphore_signal(e->wake);
    }
}

// ---------------------------------------------------------------------------
// Lifecycle and settings
// ---------------------------------------------------------------------------

kc_engine *kc_engine_create(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&g_timebase); });

    // Page-aligned, zeroed and wired: the audio thread must not page-fault here.
    kc_engine *e = NULL;
    if (posix_memalign((void **)&e, 16384, sizeof(kc_engine)) != 0) return NULL;
    memset(e, 0, sizeof(kc_engine));
    mlock(e, sizeof(*e));
    atomic_init(&e->enabled, true);
    atomic_init(&e->volume, 0.5f);
    atomic_init(&e->effects_volume, 1.0f);
    atomic_init(&e->quiet_gain, 1.0f);
    atomic_init(&e->pan, true);
    atomic_init(&e->spatial, true);
    atomic_init(&e->pitch_variation, true);
    atomic_init(&e->requested_buffer_frames, KC_TARGET_BUFFER_FRAMES);
    e->rng = (uint32_t)mach_absolute_time() | 1u;
    e->ui_rng = e->rng ^ 0x9E3779B9u;
    pthread_mutex_init(&e->tone_lock, NULL);
    e->wake = dispatch_semaphore_create(0);
    publish_tone(e, 48000.0);

    AudioObjectAddPropertyListener(kAudioObjectSystemObject, &kDefaultOutputAddr, device_changed, e);
    pthread_create(&e->control, NULL, control_thread, e);
    dispatch_semaphore_signal(e->wake); // prewarm the output
    return e;
}

void kc_engine_destroy(kc_engine *e) {
    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &kDefaultOutputAddr, device_changed, e);
    kc_tap_stop(e);
    atomic_store(&e->shutdown, true);
    dispatch_semaphore_signal(e->wake);
    pthread_join(e->control, NULL);
    if (e->pack_map) munmap(e->pack_map, e->pack_size);
    pthread_mutex_destroy(&e->tone_lock);
    free(e);
}

void kc_engine_set_enabled(kc_engine *e, bool v) { atomic_store(&e->enabled, v); }
void kc_engine_set_profile(kc_engine *e, int p) {
    if (p >= 0 && p < atomic_load(&e->profile_count)) atomic_store(&e->profile, p);
}
void kc_engine_set_volume(kc_engine *e, float v) { atomic_store(&e->volume, v); }
void kc_engine_set_effects_volume(kc_engine *e, float v) { atomic_store(&e->effects_volume, v); }
void kc_engine_set_quiet_gain(kc_engine *e, float v) { atomic_store(&e->quiet_gain, v); }
void kc_engine_set_pan(kc_engine *e, bool v) { atomic_store(&e->pan, v); }
void kc_engine_set_spatial(kc_engine *e, bool v) { atomic_store(&e->spatial, v); }
void kc_engine_set_pitch_variation(kc_engine *e, bool v) { atomic_store(&e->pitch_variation, v); }
void kc_engine_set_ignore_rapid(kc_engine *e, bool v) { atomic_store(&e->ignore_rapid, v); }
void kc_engine_set_mute_modifiers(kc_engine *e, bool v) { atomic_store(&e->mute_modifiers, v); }
void kc_engine_set_mouse_sounds(kc_engine *e, bool v) { atomic_store(&e->mouse_sounds, v); }
void kc_engine_set_return_ding(kc_engine *e, bool v) { atomic_store(&e->return_ding, v); }
void kc_engine_set_output_device(kc_engine *e, uint32_t device) {
    atomic_store(&e->requested_device, device);
    atomic_store(&e->needs_rebuild, true);
    dispatch_semaphore_signal(e->wake);
}

void kc_engine_set_buffer_frames(kc_engine *e, uint32_t frames) {
    if (frames == 0 || frames == atomic_load(&e->requested_buffer_frames)) return;
    atomic_store(&e->requested_buffer_frames, frames);
    atomic_store(&e->needs_rebuild, true);
    dispatch_semaphore_signal(e->wake);
}

uint64_t kc_engine_key_count(const kc_engine *e) { return atomic_load(&e->key_count); }
bool kc_engine_is_running(const kc_engine *e) { return atomic_load(&e->running_flag); }

void kc_engine_get_stats(const kc_engine *e, kc_stats *out) {
    memset(out, 0, sizeof(*out));
    const kc_latency *s = &e->latency;
    uint64_t n = atomic_load_explicit(&s->count, memory_order_acquire);
    out->count = n;
    out->last_ms = s->last_ms;
    out->min_ms = s->min_ms;
    out->max_ms = s->max_ms;
    out->mean_ms = n ? s->sum_ms / (double)n : 0;
    out->device_ms = e->device_latency_ms;
    out->sample_rate = e->device_rate;
    out->buffer_frames = e->buffer_frames;
    out->cold_starts = e->cold_starts;
    out->last_cold_start_ms = e->last_cold_start_ms;
    out->running = atomic_load(&e->running_flag);
}

static void push_ui(kc_engine *e, int profile, int klass, int up, double delay, bool effect) {
    const float *data;
    uint32_t len;
    e->ui_rng ^= e->ui_rng << 13; e->ui_rng ^= e->ui_rng >> 17; e->ui_rng ^= e->ui_rng << 5;
    if (!kc_lookup_sound(e, profile, klass, up, e->ui_rng, &data, &len) &&
        !kc_lookup_sound(e, profile, klass, up, 0, &data, &len)) {
        return; // the bell has one take, in the first slot
    }
    uint64_t now = mach_absolute_time();
    kc_trigger t = {.data = data, .length = len, .position = 0, .gain = 1, .rate = 1,
                    .delay_seconds = delay, .host_time = now, .effect = effect, .preview = true};
    kc_ring_push(&e->ui_ring, &t);
    kc_note_activity(e, now);
}

void kc_engine_preview_profile(kc_engine *e, int profile) {
    push_ui(e, profile, KC_CLASS_ALPHA, 0, 0.0, false);
    push_ui(e, profile, KC_CLASS_ALPHA, 1, 0.085, false);
}

void kc_engine_preview_effect(kc_engine *e, kc_effect effect) {
    int bank = atomic_load(&e->profile_count);
    push_ui(e, bank, (int)effect, 0, 0.0, true);
    if (effect == KC_EFFECT_MOUSE) push_ui(e, bank, (int)effect, 1, 0.09, true);
}
