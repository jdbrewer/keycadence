// Physical layout of the ANSI Mac keyboard, by virtual keycode.
#include "keycadence.h"

// Horizontal centre of each key in key-widths from the left edge (0..15).
// Negative means "unknown": treated as centre.
static const float kPositions[128] = {
    [0x35] = 0.5f,  // esc
    [0x7A] = 1.5f,  [0x78] = 2.5f,  [0x63] = 3.5f,  [0x76] = 4.5f,  // F1-F4
    [0x60] = 5.5f,  [0x61] = 6.5f,  [0x62] = 7.5f,  [0x64] = 8.5f,  // F5-F8
    [0x65] = 9.5f,  [0x6D] = 10.5f, [0x67] = 11.5f, [0x6F] = 12.5f, // F9-F12
    [0x32] = 0.5f,  // `
    [0x12] = 1.5f,  [0x13] = 2.5f,  [0x14] = 3.5f,  [0x15] = 4.5f,  // 1-4
    [0x17] = 5.5f,  [0x16] = 6.5f,  [0x1A] = 7.5f,  [0x1C] = 8.5f,  // 5-8
    [0x19] = 9.5f,  [0x1D] = 10.5f, [0x1B] = 11.5f, [0x18] = 12.5f, // 9 0 - =
    [0x33] = 14.0f, // delete
    [0x30] = 0.75f, // tab
    [0x0C] = 2.0f,  [0x0D] = 3.0f,  [0x0E] = 4.0f,  [0x0F] = 5.0f,  // q w e r
    [0x11] = 6.0f,  [0x10] = 7.0f,  [0x20] = 8.0f,  [0x22] = 9.0f,  // t y u i
    [0x1F] = 10.0f, [0x23] = 11.0f, [0x21] = 12.0f, [0x1E] = 13.0f, // o p [ ]
    [0x2A] = 14.25f, // backslash
    [0x39] = 0.9f,  // caps lock
    [0x00] = 2.25f, [0x01] = 3.25f, [0x02] = 4.25f, [0x03] = 5.25f, // a s d f
    [0x05] = 6.25f, [0x04] = 7.25f, [0x26] = 8.25f, [0x28] = 9.25f, // g h j k
    [0x25] = 10.25f, [0x29] = 11.25f, [0x27] = 12.25f,              // l ; '
    [0x24] = 14.1f, // return
    [0x38] = 1.1f,  // left shift
    [0x06] = 2.75f, [0x07] = 3.75f, [0x08] = 4.75f, [0x09] = 5.75f, // z x c v
    [0x0B] = 6.75f, [0x2D] = 7.75f, [0x2E] = 8.75f, [0x2B] = 9.75f, // b n m ,
    [0x2F] = 10.75f, [0x2C] = 11.75f,                               // . /
    [0x3C] = 13.6f, // right shift
    [0x3F] = 0.5f,  // fn
    [0x3B] = 1.5f,  // left control
    [0x3A] = 2.5f,  // left option
    [0x37] = 3.75f, // left command
    [0x31] = 7.25f, // space
    [0x36] = 10.75f, // right command
    [0x3D] = 12.0f, // right option
    [0x3E] = 13.0f, // right control
    [0x7B] = 13.0f, [0x7D] = 13.75f, [0x7C] = 14.5f, [0x7E] = 13.75f, // arrows
};

float kc_key_position_for_keycode(uint16_t keycode) {
    if (keycode >= 128) return 0.0f;
    float p = kPositions[keycode];
    if (p <= 0.0f) return 0.0f;
    return (p / 7.5f) - 1.0f;
}

kc_key_class kc_key_class_for_keycode(uint16_t keycode) {
    switch (keycode) {
    case 0x31:
        return KC_CLASS_SPACE;
    case 0x24: case 0x4C:
        return KC_CLASS_RETURN;
    case 0x33: case 0x75:
        return KC_CLASS_BACKSPACE;
    case 0x36: case 0x37: case 0x38: case 0x39: case 0x3A:
    case 0x3B: case 0x3C: case 0x3D: case 0x3E: case 0x3F:
        return KC_CLASS_MODIFIER;
    default:
        return KC_CLASS_ALPHA;
    }
}
