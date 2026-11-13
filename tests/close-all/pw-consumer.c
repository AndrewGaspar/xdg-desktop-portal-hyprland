// Minimal PipeWire video consumer for tests/close-all: plays the part of the app that reads a
// screencast stream, so XDPH actually captures frames. Prints its state, node id and frame count.
//
//   pw-consumer <name>
//
// There is no session manager in the test, so this doesn't autoconnect: link it with pw-link.

#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>

#include <signal.h>
#include <stdio.h>

struct SData {
    struct pw_main_loop* loop;
    struct pw_stream*    stream;
    struct spa_hook      listener;
    unsigned long        frames;
};

static void onProcess(void* userdata) {
    struct SData*     d = userdata;
    struct pw_buffer* b = pw_stream_dequeue_buffer(d->stream);

    if (!b)
        return;

    d->frames++;
    pw_stream_queue_buffer(d->stream, b);

    if (d->frames == 1 || d->frames % 10 == 0) {
        printf("frames %lu\n", d->frames);
        fflush(stdout);
    }
}

static void onStateChanged(void* userdata, enum pw_stream_state old, enum pw_stream_state state, const char* error) {
    struct SData* d = userdata;

    printf("state %s node %u%s%s\n", pw_stream_state_as_string(state), pw_stream_get_node_id(d->stream), error ? " error: " : "", error ? error : "");
    fflush(stdout);
}

static void onParamChanged(void* userdata, uint32_t id, const struct spa_pod* param) {
    struct SData* d = userdata;

    if (!param || id != SPA_PARAM_Format)
        return;

    struct spa_video_info_raw info = {0};
    spa_format_video_raw_parse(param, &info);
    printf("format %u %ux%u\n", info.format, info.size.width, info.size.height);
    fflush(stdout);

    uint8_t                buffer[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    const struct spa_pod*  params[1];
    params[0] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers, SPA_PARAM_BUFFERS_dataType,
                                           SPA_POD_CHOICE_FLAGS_Int((1 << SPA_DATA_MemFd) | (1 << SPA_DATA_MemPtr)));
    pw_stream_update_params(d->stream, params, 1);
}

static const struct pw_stream_events streamEvents = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = onStateChanged,
    .param_changed = onParamChanged,
    .process       = onProcess,
};

static void onSignal(void* userdata, int signo) {
    struct SData* d = userdata;
    pw_main_loop_quit(d->loop);
}

int main(int argc, char** argv) {
    struct SData d = {0};

    pw_init(&argc, &argv);

    d.loop = pw_main_loop_new(NULL);
    pw_loop_add_signal(pw_main_loop_get_loop(d.loop), SIGINT, onSignal, &d);
    pw_loop_add_signal(pw_main_loop_get_loop(d.loop), SIGTERM, onSignal, &d);

    d.stream = pw_stream_new_simple(pw_main_loop_get_loop(d.loop), argc > 1 ? argv[1] : "xca-consumer",
                                    pw_properties_new(PW_KEY_MEDIA_TYPE, "Video", PW_KEY_MEDIA_CATEGORY, "Capture", PW_KEY_MEDIA_ROLE, "Screen", NULL), &streamEvents, &d);

    uint8_t                buffer[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    const struct spa_pod*  params[1];
    params[0] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat, SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video), SPA_FORMAT_mediaSubtype,
                                           SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw), SPA_FORMAT_VIDEO_format,
                                           SPA_POD_CHOICE_ENUM_Id(7, SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRA, SPA_VIDEO_FORMAT_RGBx,
                                                                  SPA_VIDEO_FORMAT_RGBA, SPA_VIDEO_FORMAT_xRGB, SPA_VIDEO_FORMAT_xBGR),
                                           SPA_FORMAT_VIDEO_size, SPA_POD_CHOICE_RANGE_Rectangle(&SPA_RECTANGLE(1280, 720), &SPA_RECTANGLE(1, 1), &SPA_RECTANGLE(8192, 8192)),
                                           SPA_FORMAT_VIDEO_framerate, SPA_POD_CHOICE_RANGE_Fraction(&SPA_FRACTION(0, 1), &SPA_FRACTION(0, 1), &SPA_FRACTION(1000, 1)));

    pw_stream_connect(d.stream, PW_DIRECTION_INPUT, PW_ID_ANY, PW_STREAM_FLAG_MAP_BUFFERS, params, 1);

    pw_main_loop_run(d.loop);

    pw_stream_destroy(d.stream);
    pw_main_loop_destroy(d.loop);
    pw_deinit();
    return 0;
}
