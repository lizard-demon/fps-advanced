#!/bin/bash

# Audio conversion script for game engine.
# Converts any audio format to mono 44.1kHz 16-bit raw PCM

set -e

if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    echo "Usage: $0 <input_file> [output_file]"
    echo "Converts audio to mono 44.1kHz 16-bit raw PCM for the game engine."
    exit 0
fi

INPUT="$1"
OUTPUT="${2:-${INPUT%.*}.pcm}"

[ ! -f "$INPUT" ] && { echo "Error: Input file '$INPUT' not found"; exit 1; }

if ! command -v ffmpeg &> /dev/null; then
    echo "Error: ffmpeg not found"
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"

ffmpeg -i "$INPUT" -ar 44100 -ac 1 -f s16le -y "$OUTPUT"