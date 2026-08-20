// A small mixer over miniaudio for lens audio playback. Sounds decode once
// into cached s16 PCM (no device, no clock: MA_NO_DEVICE_IO); each play adds
// a voice the pull mixes and advances. Deterministic - the same play/pull
// sequence yields the same PCM, so a triggered sound is conformance-stable.
#define MA_NO_DEVICE_IO
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#include <stdlib.h>
#include <string.h>

#define GOSS_MAX_SOUNDS 32
#define GOSS_MAX_VOICES 32

typedef struct { short *pcm; ma_uint64 frames; } Sound;
typedef struct { int sound; ma_uint64 cursor; int loop; float gain; int active; } Voice;

typedef struct GossMixer {
    int sample_rate;
    int channels;
    int sound_count;
    Sound sounds[GOSS_MAX_SOUNDS];
    Voice voices[GOSS_MAX_VOICES];
} GossMixer;

GossMixer *goss_mixer_create(int sample_rate, int channels);
void goss_mixer_destroy(GossMixer *m);
int goss_mixer_load(GossMixer *m, const char *path, size_t path_len);
int goss_mixer_load_memory(GossMixer *m, const void *data, size_t size);
void goss_mixer_play(GossMixer *m, int sound_id, int loop, float gain);
int goss_mixer_active_voices(const GossMixer *m);
void goss_mixer_pull(GossMixer *m, short *out, int frames);

// Shared: decode an already-initialized ma_decoder fully into a cached
// sound, returning its id or -1.
static int goss_mixer_take(GossMixer *m, ma_decoder *dec) {
    ma_uint64 total = 0;
    ma_decoder_get_length_in_pcm_frames(dec, &total);
    if (total == 0) { ma_decoder_uninit(dec); return -1; }
    short *pcm = (short *)malloc((size_t)total * m->channels * sizeof(short));
    if (!pcm) { ma_decoder_uninit(dec); return -1; }
    ma_uint64 got = 0;
    ma_decoder_read_pcm_frames(dec, pcm, total, &got);
    ma_decoder_uninit(dec);
    int id = m->sound_count++;
    m->sounds[id].pcm = pcm;
    m->sounds[id].frames = got;
    return id;
}

GossMixer *goss_mixer_create(int sample_rate, int channels) {
    GossMixer *m = (GossMixer *)calloc(1, sizeof(GossMixer));
    if (!m) return NULL;
    m->sample_rate = sample_rate;
    m->channels = channels;
    return m;
}

void goss_mixer_destroy(GossMixer *m) {
    if (!m) return;
    for (int i = 0; i < m->sound_count; i++) free(m->sounds[i].pcm);
    free(m);
}

// Decodes a sound file into cached PCM at the mixer's rate and channels,
// returning its id, or -1 on failure or when the sound table is full.
int goss_mixer_load(GossMixer *m, const char *path, size_t path_len) {
    if (!m || m->sound_count >= GOSS_MAX_SOUNDS) return -1;
    char pbuf[1024];
    if (path_len >= sizeof(pbuf)) return -1;
    memcpy(pbuf, path, path_len);
    pbuf[path_len] = '\0';

    ma_decoder_config cfg = ma_decoder_config_init(ma_format_s16, m->channels, m->sample_rate);
    ma_decoder dec;
    if (ma_decoder_init_file(pbuf, &cfg, &dec) != MA_SUCCESS) return -1;
    return goss_mixer_take(m, &dec);
}

int goss_mixer_load_memory(GossMixer *m, const void *data, size_t size) {
    if (!m || m->sound_count >= GOSS_MAX_SOUNDS) return -1;
    ma_decoder_config cfg = ma_decoder_config_init(ma_format_s16, m->channels, m->sample_rate);
    ma_decoder dec;
    if (ma_decoder_init_memory(data, size, &cfg, &dec) != MA_SUCCESS) return -1;
    return goss_mixer_take(m, &dec);
}

void goss_mixer_play(GossMixer *m, int sound_id, int loop, float gain) {
    if (!m || sound_id < 0 || sound_id >= m->sound_count) return;
    for (int i = 0; i < GOSS_MAX_VOICES; i++) {
        if (!m->voices[i].active) {
            m->voices[i].sound = sound_id;
            m->voices[i].cursor = 0;
            m->voices[i].loop = loop;
            m->voices[i].gain = gain;
            m->voices[i].active = 1;
            return;
        }
    }
}

int goss_mixer_active_voices(const GossMixer *m) {
    if (!m) return 0;
    int n = 0;
    for (int i = 0; i < GOSS_MAX_VOICES; i++) n += m->voices[i].active;
    return n;
}

// Mixes every active voice into out (frames * channels, s16), advancing each
// by frames. A non-looping voice deactivates when it reaches its end.
void goss_mixer_pull(GossMixer *m, short *out, int frames) {
    int ch = m ? m->channels : 1;
    memset(out, 0, (size_t)frames * ch * sizeof(short));
    if (!m) return;
    for (int v = 0; v < GOSS_MAX_VOICES; v++) {
        Voice *vo = &m->voices[v];
        if (!vo->active) continue;
        Sound *s = &m->sounds[vo->sound];
        for (int f = 0; f < frames; f++) {
            if (vo->cursor >= s->frames) {
                if (vo->loop) vo->cursor = 0;
                else { vo->active = 0; break; }
            }
            for (int c = 0; c < ch; c++) {
                long mixed = out[f * ch + c] + (long)(s->pcm[vo->cursor * ch + c] * vo->gain);
                if (mixed > 32767) mixed = 32767;
                if (mixed < -32768) mixed = -32768;
                out[f * ch + c] = (short)mixed;
            }
            vo->cursor++;
            // A one-shot voice retires the instant it plays its last sample,
            // so it is inactive immediately, not on the next pull.
            if (!vo->loop && vo->cursor >= s->frames) { vo->active = 0; break; }
        }
    }
}
