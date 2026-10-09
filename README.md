# Recorder

A small macOS 15+ menu bar screen recorder. Pick a screen, window, or region, then set the resolution, frame rate, codec, bitrate, computer audio, and mic. Click Record. While it records, the menu bar shows elapsed time and the file's current size. Click the red icon to stop, and the file is revealed in Finder.

## How it works

ScreenCaptureKit delivers frames already scaled to the output size on the GPU. Each frame goes directly to the hardware H.264/HEVC encoder through AVAssetWriter, so only compressed video reaches disk and the bitrate setting caps file size. Output is a fragmented `.mov` (fragments every 5 s), so a crash loses only the last few seconds. Computer audio and the mic are recorded as separate AAC tracks.

## Build and run

    bash scripts/build.sh      # -> build/Recorder.app
    open build/Recorder.app

The first recording asks for Screen Recording permission (and Microphone if enabled). After granting Screen Recording, quit and reopen Recorder. Grants survive rebuilds because `build.sh` signs with a stable self-signed cert; see the comment at the top of that script.

## Tests

    swift test                                                            # sizing/naming unit tests
    build/Recorder.app/Contents/MacOS/Recorder --smoke-test 4 /tmp/s.mov  # real 4 s capture of the main display, then checks size/duration/tracks/bytes

The smoke test runs under your terminal's Screen Recording permission.
