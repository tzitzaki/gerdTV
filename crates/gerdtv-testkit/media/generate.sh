#!/usr/bin/env bash
# Regenerates the synthetic test media (committed, so CI needs no ffmpeg): a 10 s colour-bars clip with a 1 kHz tone,
# H.264 + AAC at a low bitrate, as one MPEG-TS file and as five 2 s HLS segments with a keyframe at each start.
# Generated content only (ffmpeg's testsrc2/sine sources); no real broadcast material.
# Usage: crates/gerdtv-testkit/media/generate.sh   (needs ffmpeg)
set -euo pipefail
cd "$(dirname "$0")"
src=(-f lavfi -i "testsrc2=size=320x180:rate=25:duration=10" -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=10")
enc=(-c:v libx264 -profile:v baseline -preset veryfast -b:v 150k -g 50 -keyint_min 50 -sc_threshold 0 -c:a aac -b:a 48k -ac 1 -map_metadata -1 -fflags +bitexact -flags:v +bitexact -flags:a +bitexact)
ffmpeg -loglevel error -y "${src[@]}" "${enc[@]}" -f mpegts clip.ts
rm -f seg*.ts
ffmpeg -loglevel error -y "${src[@]}" "${enc[@]}" -f hls -hls_time 2 -hls_list_size 0 -hls_segment_filename 'seg%d.ts' clip.m3u8
rm -f clip.m3u8   # the fault server writes its own (sliding, looping) playlists
ls -l clip.ts seg*.ts
