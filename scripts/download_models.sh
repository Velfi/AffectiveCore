#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

models_dir="models"
mkdir -p "$models_dir"

download() {
  url="$1"
  output="$2"
  tmp="${output}.tmp"

  printf "Downloading %s\n" "$output"
  curl --fail --location --show-error --progress-bar --output "$tmp" "$url"
  mv "$tmp" "$output"
}

download \
  "https://raw.githubusercontent.com/opencv/opencv_zoo/main/models/face_detection_yunet/face_detection_yunet_2023mar_int8.onnx" \
  "$models_dir/face_detection_yunet_2023mar_int8.onnx"

download \
  "https://raw.githubusercontent.com/opencv/opencv_zoo/main/models/face_recognition_sface/face_recognition_sface_2021dec_int8.onnx" \
  "$models_dir/face_recognition_sface_2021dec_int8.onnx"

download \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin" \
  "$models_dir/ggml-base.en.bin"

printf "Downloaded models into %s/\n" "$models_dir"
