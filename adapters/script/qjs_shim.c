// A small C shim over QuickJS-ng that hides JSValue (passed by value, an
// unstable ABI across the Zig boundary) behind a plain interface, the same
// pattern as the jolt and gpupixel shims. The script runs hardened (no
// clock, no RNG) and fuel-bounded, so it can never hang or vary per run.
#include <stdlib.h>
#include <string.h>
#include "quickjs.h"

typedef struct GossScript {
    JSRuntime *rt;
    JSContext *ctx;
    long budget;
    long fuel_per_tick;
    int has_update;
} GossScript;

GossScript *goss_script_new(const char *source, size_t source_len, long fuel_per_tick);
void goss_script_free(GossScript *s);
int goss_script_tick(GossScript *s,
                     const char *const *signal_names, const double *signal_values, int signal_count,
                     const char *const *param_names, double *param_values, int param_count);

// Non-zero return interrupts the running script; the budget is refilled
// before each eval and each tick, so runaway code stops but normal code
// gets a full allowance every frame.
static int goss_on_interrupt(JSRuntime *rt, void *opaque) {
    GossScript *s = (GossScript *)opaque;
    (void)rt;
    if (s->budget <= 0) return 1;
    s->budget--;
    return 0;
}

// Creates a hardened context and evaluates the lens script's top level,
// which is expected to define a global update(lens) function. Returns NULL
// on any failure (bad runtime, syntax error, no update function).
GossScript *goss_script_new(const char *source, size_t source_len, long fuel_per_tick) {
    GossScript *s = (GossScript *)calloc(1, sizeof(GossScript));
    if (!s) return NULL;
    s->rt = JS_NewRuntime();
    if (!s->rt) { free(s); return NULL; }
    s->ctx = JS_NewContext(s->rt);
    if (!s->ctx) { JS_FreeRuntime(s->rt); free(s); return NULL; }
    s->fuel_per_tick = fuel_per_tick > 0 ? fuel_per_tick : 1000000;
    JS_SetInterruptHandler(s->rt, goss_on_interrupt, s);

    s->budget = s->fuel_per_tick;
    const char *harden = "delete globalThis.Date; delete Math.random;";
    JSValue h = JS_Eval(s->ctx, harden, strlen(harden), "<harden>", JS_EVAL_TYPE_GLOBAL);
    JS_FreeValue(s->ctx, h);

    // JS_Eval needs a null-terminated buffer even with an explicit length,
    // and the source slice from the lens is not, so copy it terminated.
    char *buf = (char *)malloc(source_len + 1);
    if (!buf) { goss_script_free(s); return NULL; }
    memcpy(buf, source, source_len);
    buf[source_len] = '\0';
    s->budget = s->fuel_per_tick;
    JSValue v = JS_Eval(s->ctx, buf, source_len, "<lens>", JS_EVAL_TYPE_GLOBAL);
    free(buf);
    int failed = JS_IsException(v);
    JS_FreeValue(s->ctx, v);
    if (failed) { goss_script_free(s); return NULL; }

    JSValue global = JS_GetGlobalObject(s->ctx);
    JSValue upd = JS_GetPropertyStr(s->ctx, global, "update");
    s->has_update = JS_IsFunction(s->ctx, upd);
    JS_FreeValue(s->ctx, upd);
    JS_FreeValue(s->ctx, global);
    if (!s->has_update) { goss_script_free(s); return NULL; }
    return s;
}

void goss_script_free(GossScript *s) {
    if (!s) return;
    if (s->ctx) JS_FreeContext(s->ctx);
    if (s->rt) JS_FreeRuntime(s->rt);
    free(s);
}

// Runs update(lens) once. The host passes the current signals in and the
// current parameter values in/out: the script reads lens.signals.<name>
// and writes lens.params.<name>, and the written values are read back into
// param_values. Returns 0 on success, -1 on an exception or fuel timeout.
int goss_script_tick(GossScript *s,
                     const char *const *signal_names, const double *signal_values, int signal_count,
                     const char *const *param_names, double *param_values, int param_count) {
    if (!s || !s->has_update) return -1;
    JSContext *ctx = s->ctx;
    s->budget = s->fuel_per_tick;

    JSValue lens = JS_NewObject(ctx);
    JSValue signals = JS_NewObject(ctx);
    for (int i = 0; i < signal_count; i++)
        JS_SetPropertyStr(ctx, signals, signal_names[i], JS_NewFloat64(ctx, signal_values[i]));
    JS_SetPropertyStr(ctx, lens, "signals", signals);
    JSValue params = JS_NewObject(ctx);
    for (int i = 0; i < param_count; i++)
        JS_SetPropertyStr(ctx, params, param_names[i], JS_NewFloat64(ctx, param_values[i]));
    JS_SetPropertyStr(ctx, lens, "params", params);

    JSValue global = JS_GetGlobalObject(ctx);
    JSValue update = JS_GetPropertyStr(ctx, global, "update");
    JSValue ret = JS_Call(ctx, update, JS_UNDEFINED, 1, &lens);
    int rc = JS_IsException(ret) ? -1 : 0;
    JS_FreeValue(ctx, ret);
    JS_FreeValue(ctx, update);
    JS_FreeValue(ctx, global);

    if (rc == 0) {
        JSValue p = JS_GetPropertyStr(ctx, lens, "params");
        for (int i = 0; i < param_count; i++) {
            JSValue val = JS_GetPropertyStr(ctx, p, param_names[i]);
            double d;
            if (JS_ToFloat64(ctx, &d, val) == 0) param_values[i] = d;
            JS_FreeValue(ctx, val);
        }
        JS_FreeValue(ctx, p);
    }
    JS_FreeValue(ctx, lens);
    return rc;
}
