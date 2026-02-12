# Chapter 11: The FFmpeg Plugin - A Complete Example

*"FFmpeg: Because media is complicated, but using it shouldn't be."*

---

FFmpeg is the Swiss Army knife of multimedia. It handles virtually every audio and video format ever created. This chapter walks through building a complete, production-ready FFmpeg plugin for ARO—from installation to implementation to real-world usage.

## 11.1 What We're Building

By the end of this chapter, you'll have a plugin that can:

- **Transcode video**: Convert between formats (MP4, WebM, AVI, etc.)
- **Extract audio**: Pull audio tracks from video files
- **Generate thumbnails**: Create preview images from video
- **Get media info**: Retrieve duration, resolution, codecs, bitrate
- **Create clips**: Extract segments from longer videos

This is a substantial plugin—the kind you'd actually use in production.

## 11.2 Installing FFmpeg

FFmpeg must be installed on your system before building the plugin.

### macOS (Homebrew)

```bash
brew install ffmpeg

# Verify installation
ffmpeg -version
# Output: ffmpeg version 6.1 ...

# Check library paths
brew --prefix ffmpeg
# Output: /opt/homebrew/opt/ffmpeg
```

### Ubuntu/Debian

```bash
sudo apt update
sudo apt install ffmpeg libavcodec-dev libavformat-dev libavutil-dev libswscale-dev

# Verify
ffmpeg -version
pkg-config --libs libavcodec libavformat
```

### Windows

1. Download from https://www.gyan.dev/ffmpeg/builds/
2. Extract to `C:\ffmpeg`
3. Add `C:\ffmpeg\bin` to PATH
4. For development, install vcpkg and run:
   ```
   vcpkg install ffmpeg
   ```

### Verifying the Installation

```bash
# Check FFmpeg is accessible
which ffmpeg
ffmpeg -version

# Check development libraries (needed for C plugins)
pkg-config --cflags --libs libavcodec libavformat libavutil libswscale
```

## 11.3 Project Structure

```
Plugins/
└── plugin-c-ffmpeg/
    ├── plugin.yaml
    ├── README.md
    └── src/
        ├── ffmpeg_plugin.c
        ├── ffmpeg_plugin.h
        ├── transcode.c
        ├── thumbnail.c
        ├── info.c
        └── utils.c
```

## 11.4 Plugin Manifest

```yaml
# plugin.yaml
name: plugin-c-ffmpeg
version: 1.0.0
description: "Video processing with FFmpeg - transcode, thumbnails, audio extraction"
author: "ARO Team"
license: MIT
aro-version: ">=0.1.0"

provides:
  - type: c-plugin
    path: src/
    build:
      compiler: clang
      flags:
        - -O2
        - -fPIC
        - -shared
        - -I/opt/homebrew/include        # macOS Homebrew
        - -I/usr/local/include           # Linux/manual install
      link:
        - -L/opt/homebrew/lib
        - -L/usr/local/lib
        - -lavcodec
        - -lavformat
        - -lavutil
        - -lswscale
        - -lswresample
      output: libffmpeg_plugin.dylib

# Document system requirements
requirements:
  system:
    - name: ffmpeg
      min-version: "5.0"
      install:
        macos: "brew install ffmpeg"
        ubuntu: "apt install ffmpeg libavcodec-dev libavformat-dev libavutil-dev"
```

## 11.5 Header File

```c
// ffmpeg_plugin.h
#ifndef FFMPEG_PLUGIN_H
#define FFMPEG_PLUGIN_H

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>

// Result helpers
char* success_result(const char* json_body);
char* error_result(const char* message);

// JSON helpers (simple implementation)
char* extract_json_string(const char* json, const char* key);
int extract_json_int(const char* json, const char* key, int default_value);
double extract_json_double(const char* json, const char* key, double default_value);

// Actions
char* action_info(const char* input_json);
char* action_transcode(const char* input_json);
char* action_thumbnail(const char* input_json);
char* action_extract_audio(const char* input_json);
char* action_clip(const char* input_json);

#endif // FFMPEG_PLUGIN_H
```

## 11.6 Main Plugin Implementation

```c
// ffmpeg_plugin.c
#include "ffmpeg_plugin.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ============================================================
// Plugin Interface
// ============================================================

char* aro_plugin_info(void) {
    return strdup(
        "{"
        "\"name\":\"plugin-c-ffmpeg\","
        "\"version\":\"1.0.0\","
        "\"language\":\"c\","
        "\"actions\":[\"info\",\"transcode\",\"thumbnail\",\"extract-audio\",\"clip\"]"
        "}"
    );
}

char* aro_plugin_execute(const char* action, const char* input_json) {
    if (!action || !input_json) {
        return error_result("Null input");
    }

    if (strcmp(action, "info") == 0) {
        return action_info(input_json);
    }
    else if (strcmp(action, "transcode") == 0) {
        return action_transcode(input_json);
    }
    else if (strcmp(action, "thumbnail") == 0) {
        return action_thumbnail(input_json);
    }
    else if (strcmp(action, "extract-audio") == 0) {
        return action_extract_audio(input_json);
    }
    else if (strcmp(action, "clip") == 0) {
        return action_clip(input_json);
    }

    char msg[256];
    snprintf(msg, sizeof(msg), "Unknown action: %s", action);
    return error_result(msg);
}

void aro_plugin_free(char* ptr) {
    if (ptr) free(ptr);
}

// ============================================================
// JSON Helpers
// ============================================================

char* extract_json_string(const char* json, const char* key) {
    char search[256];
    snprintf(search, sizeof(search), "\"%s\":", key);

    const char* pos = strstr(json, search);
    if (!pos) return NULL;

    pos = strchr(pos, ':');
    if (!pos) return NULL;
    pos++;

    while (*pos == ' ' || *pos == '\t' || *pos == '\n') pos++;

    if (*pos != '"') return NULL;
    pos++;

    const char* end = strchr(pos, '"');
    if (!end) return NULL;

    size_t len = end - pos;
    char* result = malloc(len + 1);
    if (result) {
        memcpy(result, pos, len);
        result[len] = '\0';
    }
    return result;
}

int extract_json_int(const char* json, const char* key, int default_value) {
    char search[256];
    snprintf(search, sizeof(search), "\"%s\":", key);

    const char* pos = strstr(json, search);
    if (!pos) return default_value;

    pos = strchr(pos, ':');
    if (!pos) return default_value;
    pos++;

    while (*pos == ' ') pos++;

    return atoi(pos);
}

double extract_json_double(const char* json, const char* key, double default_value) {
    char search[256];
    snprintf(search, sizeof(search), "\"%s\":", key);

    const char* pos = strstr(json, search);
    if (!pos) return default_value;

    pos = strchr(pos, ':');
    if (!pos) return default_value;
    pos++;

    while (*pos == ' ') pos++;

    return atof(pos);
}

char* success_result(const char* json_body) {
    size_t len = strlen(json_body) + 3;
    char* result = malloc(len);
    if (result) {
        snprintf(result, len, "{%s}", json_body);
    }
    return result;
}

char* error_result(const char* message) {
    size_t len = strlen(message) + 32;
    char* result = malloc(len);
    if (result) {
        snprintf(result, len, "{\"error\":\"%s\"}", message);
    }
    return result;
}
```

## 11.7 Media Info Action

```c
// info.c
#include "ffmpeg_plugin.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

char* action_info(const char* input_json) {
    char* path = extract_json_string(input_json, "path");
    if (!path) {
        return error_result("Missing 'path' field");
    }

    AVFormatContext* fmt_ctx = NULL;
    int ret = avformat_open_input(&fmt_ctx, path, NULL, NULL);
    if (ret < 0) {
        char err[256];
        av_strerror(ret, err, sizeof(err));
        free(path);
        char msg[512];
        snprintf(msg, sizeof(msg), "Cannot open file: %s", err);
        return error_result(msg);
    }

    ret = avformat_find_stream_info(fmt_ctx, NULL);
    if (ret < 0) {
        avformat_close_input(&fmt_ctx);
        free(path);
        return error_result("Cannot read stream info");
    }

    // Gather information
    double duration = (double)fmt_ctx->duration / AV_TIME_BASE;
    int64_t bitrate = fmt_ctx->bit_rate;
    const char* format_name = fmt_ctx->iformat->name;

    // Find video and audio streams
    int video_stream = -1;
    int audio_stream = -1;
    int width = 0, height = 0;
    const char* video_codec = "none";
    const char* audio_codec = "none";
    double fps = 0;
    int audio_channels = 0;
    int audio_sample_rate = 0;

    for (unsigned i = 0; i < fmt_ctx->nb_streams; i++) {
        AVCodecParameters* codecpar = fmt_ctx->streams[i]->codecpar;

        if (codecpar->codec_type == AVMEDIA_TYPE_VIDEO && video_stream < 0) {
            video_stream = i;
            width = codecpar->width;
            height = codecpar->height;

            const AVCodec* codec = avcodec_find_decoder(codecpar->codec_id);
            if (codec) video_codec = codec->name;

            AVRational frame_rate = fmt_ctx->streams[i]->avg_frame_rate;
            if (frame_rate.den > 0) {
                fps = (double)frame_rate.num / frame_rate.den;
            }
        }
        else if (codecpar->codec_type == AVMEDIA_TYPE_AUDIO && audio_stream < 0) {
            audio_stream = i;
            audio_channels = codecpar->ch_layout.nb_channels;
            audio_sample_rate = codecpar->sample_rate;

            const AVCodec* codec = avcodec_find_decoder(codecpar->codec_id);
            if (codec) audio_codec = codec->name;
        }
    }

    // Build result
    char* result = malloc(2048);
    snprintf(result, 2048,
             "{"
             "\"path\":\"%s\","
             "\"format\":\"%s\","
             "\"duration\":%.2f,"
             "\"bitrate\":%lld,"
             "\"video\":{"
             "\"codec\":\"%s\","
             "\"width\":%d,"
             "\"height\":%d,"
             "\"fps\":%.2f"
             "},"
             "\"audio\":{"
             "\"codec\":\"%s\","
             "\"channels\":%d,"
             "\"sample_rate\":%d"
             "}"
             "}",
             path, format_name, duration, (long long)bitrate,
             video_codec, width, height, fps,
             audio_codec, audio_channels, audio_sample_rate);

    avformat_close_input(&fmt_ctx);
    free(path);

    return result;
}
```

## 11.8 Thumbnail Generation

```c
// thumbnail.c
#include "ffmpeg_plugin.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

char* action_thumbnail(const char* input_json) {
    char* input_path = extract_json_string(input_json, "input");
    if (!input_path) {
        return error_result("Missing 'input' field");
    }

    char* output_path = extract_json_string(input_json, "output");
    if (!output_path) {
        free(input_path);
        return error_result("Missing 'output' field");
    }

    double timestamp = extract_json_double(input_json, "timestamp", 1.0);
    int width = extract_json_int(input_json, "width", 320);
    int height = extract_json_int(input_json, "height", 0);  // 0 = maintain aspect

    AVFormatContext* fmt_ctx = NULL;
    int ret = avformat_open_input(&fmt_ctx, input_path, NULL, NULL);
    if (ret < 0) {
        free(input_path);
        free(output_path);
        return error_result("Cannot open input file");
    }

    avformat_find_stream_info(fmt_ctx, NULL);

    // Find video stream
    int video_stream = -1;
    AVCodecParameters* codecpar = NULL;
    for (unsigned i = 0; i < fmt_ctx->nb_streams; i++) {
        if (fmt_ctx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            video_stream = i;
            codecpar = fmt_ctx->streams[i]->codecpar;
            break;
        }
    }

    if (video_stream < 0) {
        avformat_close_input(&fmt_ctx);
        free(input_path);
        free(output_path);
        return error_result("No video stream found");
    }

    // Maintain aspect ratio if height not specified
    if (height == 0) {
        height = (int)((double)codecpar->height / codecpar->width * width);
    }

    // Open decoder
    const AVCodec* decoder = avcodec_find_decoder(codecpar->codec_id);
    AVCodecContext* dec_ctx = avcodec_alloc_context3(decoder);
    avcodec_parameters_to_context(dec_ctx, codecpar);
    avcodec_open2(dec_ctx, decoder, NULL);

    // Seek to timestamp
    int64_t seek_target = (int64_t)(timestamp * AV_TIME_BASE);
    av_seek_frame(fmt_ctx, -1, seek_target, AVSEEK_FLAG_BACKWARD);

    // Read and decode frame
    AVPacket* packet = av_packet_alloc();
    AVFrame* frame = av_frame_alloc();
    AVFrame* rgb_frame = av_frame_alloc();

    int got_frame = 0;
    while (av_read_frame(fmt_ctx, packet) >= 0 && !got_frame) {
        if (packet->stream_index == video_stream) {
            ret = avcodec_send_packet(dec_ctx, packet);
            if (ret >= 0) {
                ret = avcodec_receive_frame(dec_ctx, frame);
                if (ret >= 0) {
                    got_frame = 1;
                }
            }
        }
        av_packet_unref(packet);
    }

    if (!got_frame) {
        av_frame_free(&frame);
        av_frame_free(&rgb_frame);
        av_packet_free(&packet);
        avcodec_free_context(&dec_ctx);
        avformat_close_input(&fmt_ctx);
        free(input_path);
        free(output_path);
        return error_result("Could not decode frame");
    }

    // Scale to target size
    struct SwsContext* sws_ctx = sws_getContext(
        frame->width, frame->height, dec_ctx->pix_fmt,
        width, height, AV_PIX_FMT_RGB24,
        SWS_BILINEAR, NULL, NULL, NULL
    );

    rgb_frame->format = AV_PIX_FMT_RGB24;
    rgb_frame->width = width;
    rgb_frame->height = height;
    av_frame_get_buffer(rgb_frame, 0);

    sws_scale(sws_ctx, (const uint8_t* const*)frame->data, frame->linesize,
              0, frame->height, rgb_frame->data, rgb_frame->linesize);

    // Write as PPM (simple format - could use libpng for PNG)
    FILE* outfile = fopen(output_path, "wb");
    if (outfile) {
        fprintf(outfile, "P6\n%d %d\n255\n", width, height);
        for (int y = 0; y < height; y++) {
            fwrite(rgb_frame->data[0] + y * rgb_frame->linesize[0], 1, width * 3, outfile);
        }
        fclose(outfile);
    }

    // Cleanup
    sws_freeContext(sws_ctx);
    av_frame_free(&frame);
    av_frame_free(&rgb_frame);
    av_packet_free(&packet);
    avcodec_free_context(&dec_ctx);
    avformat_close_input(&fmt_ctx);

    char* result = malloc(512);
    snprintf(result, 512,
             "{"
             "\"output\":\"%s\","
             "\"width\":%d,"
             "\"height\":%d,"
             "\"timestamp\":%.2f"
             "}",
             output_path, width, height, timestamp);

    free(input_path);
    free(output_path);

    return result;
}
```

## 11.9 Video Transcoding

```c
// transcode.c
#include "ffmpeg_plugin.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

char* action_transcode(const char* input_json) {
    char* input_path = extract_json_string(input_json, "input");
    char* output_path = extract_json_string(input_json, "output");

    if (!input_path || !output_path) {
        free(input_path);
        free(output_path);
        return error_result("Missing 'input' or 'output' field");
    }

    // Get optional parameters
    char* video_codec = extract_json_string(input_json, "video_codec");
    char* audio_codec = extract_json_string(input_json, "audio_codec");
    int width = extract_json_int(input_json, "width", 0);
    int height = extract_json_int(input_json, "height", 0);
    int video_bitrate = extract_json_int(input_json, "video_bitrate", 0);
    int audio_bitrate = extract_json_int(input_json, "audio_bitrate", 0);

    // Default codecs based on output extension
    if (!video_codec) {
        if (strstr(output_path, ".webm")) video_codec = strdup("libvpx-vp9");
        else if (strstr(output_path, ".mp4")) video_codec = strdup("libx264");
        else video_codec = strdup("libx264");
    }

    if (!audio_codec) {
        if (strstr(output_path, ".webm")) audio_codec = strdup("libopus");
        else audio_codec = strdup("aac");
    }

    // Build FFmpeg command
    // (For production, use the FFmpeg API directly for better control)
    char command[2048];

    char scale_filter[128] = "";
    if (width > 0 && height > 0) {
        snprintf(scale_filter, sizeof(scale_filter), "-vf scale=%d:%d", width, height);
    } else if (width > 0) {
        snprintf(scale_filter, sizeof(scale_filter), "-vf scale=%d:-2", width);
    }

    char video_bitrate_opt[64] = "";
    if (video_bitrate > 0) {
        snprintf(video_bitrate_opt, sizeof(video_bitrate_opt), "-b:v %dk", video_bitrate);
    }

    char audio_bitrate_opt[64] = "";
    if (audio_bitrate > 0) {
        snprintf(audio_bitrate_opt, sizeof(audio_bitrate_opt), "-b:a %dk", audio_bitrate);
    }

    snprintf(command, sizeof(command),
             "ffmpeg -y -i \"%s\" -c:v %s -c:a %s %s %s %s \"%s\" 2>&1",
             input_path, video_codec, audio_codec,
             scale_filter, video_bitrate_opt, audio_bitrate_opt,
             output_path);

    // Execute
    FILE* pipe = popen(command, "r");
    if (!pipe) {
        free(input_path);
        free(output_path);
        free(video_codec);
        free(audio_codec);
        return error_result("Failed to execute FFmpeg");
    }

    // Read output (for error checking)
    char buffer[4096] = "";
    char line[256];
    while (fgets(line, sizeof(line), pipe)) {
        if (strlen(buffer) + strlen(line) < sizeof(buffer) - 1) {
            strcat(buffer, line);
        }
    }

    int status = pclose(pipe);

    char* result;
    if (status == 0) {
        result = malloc(1024);
        snprintf(result, 1024,
                 "{"
                 "\"success\":true,"
                 "\"input\":\"%s\","
                 "\"output\":\"%s\","
                 "\"video_codec\":\"%s\","
                 "\"audio_codec\":\"%s\""
                 "}",
                 input_path, output_path, video_codec, audio_codec);
    } else {
        char msg[512];
        snprintf(msg, sizeof(msg), "Transcode failed (exit %d)", status);
        result = error_result(msg);
    }

    free(input_path);
    free(output_path);
    free(video_codec);
    free(audio_codec);

    return result;
}
```

## 11.10 Audio Extraction

```c
// In utils.c or extract_audio.c
char* action_extract_audio(const char* input_json) {
    char* input_path = extract_json_string(input_json, "input");
    char* output_path = extract_json_string(input_json, "output");

    if (!input_path || !output_path) {
        free(input_path);
        free(output_path);
        return error_result("Missing 'input' or 'output' field");
    }

    char* codec = extract_json_string(input_json, "codec");
    if (!codec) {
        // Determine from extension
        if (strstr(output_path, ".mp3")) codec = strdup("libmp3lame");
        else if (strstr(output_path, ".aac")) codec = strdup("aac");
        else if (strstr(output_path, ".ogg")) codec = strdup("libvorbis");
        else if (strstr(output_path, ".flac")) codec = strdup("flac");
        else if (strstr(output_path, ".wav")) codec = strdup("pcm_s16le");
        else codec = strdup("aac");
    }

    int bitrate = extract_json_int(input_json, "bitrate", 192);

    char command[1024];
    snprintf(command, sizeof(command),
             "ffmpeg -y -i \"%s\" -vn -c:a %s -b:a %dk \"%s\" 2>&1",
             input_path, codec, bitrate, output_path);

    int status = system(command);

    char* result;
    if (status == 0) {
        result = malloc(512);
        snprintf(result, 512,
                 "{"
                 "\"success\":true,"
                 "\"input\":\"%s\","
                 "\"output\":\"%s\","
                 "\"codec\":\"%s\","
                 "\"bitrate\":%d"
                 "}",
                 input_path, output_path, codec, bitrate);
    } else {
        result = error_result("Audio extraction failed");
    }

    free(input_path);
    free(output_path);
    free(codec);

    return result;
}
```

## 11.11 Using the Plugin in ARO

```aro
(Video Processing: Application-Start) {
    <Log> "Starting video processing demo..." to the <console>.

    (* Get media information *)
    <Call> the <info> from the <plugin-c-ffmpeg: info> with {
        path: "input.mp4"
    }.

    <Log> "Video info:" to the <console>.
    <Log> "  Duration: " with <info: duration> to the <console>.
    <Log> "  Resolution: " with <info: video: width> to the <console>.
    <Log> "  Video codec: " with <info: video: codec> to the <console>.

    (* Generate thumbnail at 5 seconds *)
    <Call> the <thumb> from the <plugin-c-ffmpeg: thumbnail> with {
        input: "input.mp4",
        output: "thumbnail.ppm",
        timestamp: 5.0,
        width: 320
    }.
    <Log> "Thumbnail created: " with <thumb: output> to the <console>.

    (* Transcode to WebM for web delivery *)
    <Call> the <webm> from the <plugin-c-ffmpeg: transcode> with {
        input: "input.mp4",
        output: "output.webm",
        video_codec: "libvpx-vp9",
        audio_codec: "libopus",
        width: 1280,
        video_bitrate: 2000,
        audio_bitrate: 128
    }.
    <Log> "Transcoded to WebM" to the <console>.

    (* Extract audio for podcast *)
    <Call> the <audio> from the <plugin-c-ffmpeg: extract-audio> with {
        input: "input.mp4",
        output: "podcast.mp3",
        bitrate: 192
    }.
    <Log> "Audio extracted: " with <audio: output> to the <console>.

    <Return> an <OK: status> for the <startup>.
}
```

## 11.12 Production Considerations

### Error Handling

Always handle FFmpeg errors gracefully:

```c
if (ret < 0) {
    char err[AV_ERROR_MAX_STRING_SIZE];
    av_strerror(ret, err, sizeof(err));
    char msg[512];
    snprintf(msg, sizeof(msg), "FFmpeg error: %s", err);
    return error_result(msg);
}
```

### Memory Management

FFmpeg allocates memory that you must free:

```c
// Always free in reverse order of allocation
av_frame_free(&frame);
av_packet_free(&packet);
avcodec_free_context(&ctx);
avformat_close_input(&fmt_ctx);
```

### Thread Safety

FFmpeg contexts are not thread-safe. For concurrent operations:

```c
#include <pthread.h>

static pthread_mutex_t ffmpeg_mutex = PTHREAD_MUTEX_INITIALIZER;

char* action_info(const char* input_json) {
    pthread_mutex_lock(&ffmpeg_mutex);
    // ... FFmpeg operations ...
    pthread_mutex_unlock(&ffmpeg_mutex);
}
```

Or use separate contexts per thread.

### Resource Limits

Prevent runaway processes:

```c
// Timeout for transcoding (via system call)
snprintf(command, sizeof(command),
         "timeout 3600 ffmpeg -y -i \"%s\" ...",  // 1 hour max
         input_path);
```

## 11.13 Building the Plugin

### Makefile

```makefile
CC = clang
CFLAGS = -O2 -fPIC -shared
CFLAGS += $(shell pkg-config --cflags libavcodec libavformat libavutil libswscale)
LDFLAGS = $(shell pkg-config --libs libavcodec libavformat libavutil libswscale libswresample)

SOURCES = src/ffmpeg_plugin.c src/info.c src/thumbnail.c src/transcode.c
TARGET = libffmpeg_plugin.dylib

$(TARGET): $(SOURCES)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

clean:
	rm -f $(TARGET)

.PHONY: clean
```

### Build Commands

```bash
# Using make
make

# Manual build (macOS)
clang -O2 -fPIC -shared \
    -I/opt/homebrew/include \
    -L/opt/homebrew/lib \
    -o libffmpeg_plugin.dylib \
    src/*.c \
    -lavcodec -lavformat -lavutil -lswscale -lswresample

# Manual build (Linux)
gcc -O2 -fPIC -shared \
    $(pkg-config --cflags libavcodec libavformat) \
    -o libffmpeg_plugin.so \
    src/*.c \
    $(pkg-config --libs libavcodec libavformat libavutil libswscale libswresample)
```

## 11.14 Summary

Building a production FFmpeg plugin teaches several important lessons:

- **System Dependencies**: Document installation clearly
- **Error Handling**: FFmpeg operations can fail in many ways
- **Memory Management**: Careful allocation and deallocation
- **API vs CLI**: Use FFmpeg API for control, CLI for simplicity
- **Testing**: Test with various formats and edge cases

This plugin demonstrates that ARO can handle serious multimedia workloads through well-designed plugins.

Next, we'll explore System Objects—a way for plugins to provide custom data sources and sinks.

