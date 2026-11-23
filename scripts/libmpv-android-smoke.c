// The smoke test of gerdTV's own libmpv for Android (scripts/test-libmpv-android.sh runs it on an emulator): the
// library loads, plays the testkit's synthetic clip to its end with software decoding (no picture, no sound), and
// offers https (mbedTLS inside FFmpeg). Prints "smoke: ok" and exits 0, or names what failed and exits 1.
// Debugging: run it by hand with `adb shell LD_LIBRARY_PATH=/data/local/tmp /data/local/tmp/smoke <clip.ts>`.
#include <mpv/client.h>
#include <stdio.h>
#include <string.h>

static int fail(const char *what) {
    printf("smoke: %s\n", what);
    return 1;
}

int main(int argc, char **argv) {
    if (argc < 2) return fail("usage: smoke <file>");
    mpv_handle *h = mpv_create();
    if (!h) return fail("mpv_create failed");
    mpv_set_option_string(h, "vo", "null");
    mpv_set_option_string(h, "ao", "null");
    mpv_set_option_string(h, "hwdec", "no");
    if (mpv_initialize(h) < 0) return fail("mpv_initialize failed");
    char *protocols = mpv_get_property_string(h, "protocol-list");
    if (!protocols || !strstr(protocols, "https")) return fail("no https protocol");
    mpv_free(protocols);
    const char *cmd[] = {"loadfile", argv[1], NULL};
    if (mpv_command(h, cmd) < 0) return fail("loadfile failed");
    int64_t width = 0;
    for (;;) {
        mpv_event *e = mpv_wait_event(h, 30);
        if (e->event_id == MPV_EVENT_NONE) return fail("timed out after 30 s without an event");
        if (e->event_id == MPV_EVENT_FILE_LOADED) mpv_get_property(h, "width", MPV_FORMAT_INT64, &width);
        if (e->event_id == MPV_EVENT_END_FILE) {
            mpv_event_end_file *end = e->data;
            if (end->reason != MPV_END_FILE_REASON_EOF) return fail("playback ended before the end of the clip");
            break;
        }
    }
    if (width <= 0) return fail("no video track decoded");
    printf("smoke: ok (width %lld)\n", (long long)width);
    mpv_terminate_destroy(h);
    return 0;
}
