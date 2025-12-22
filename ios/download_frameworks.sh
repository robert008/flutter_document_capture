#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="v1.0.0"
# TODO: Update this URL when GitHub release is created
BASE_URL="https://github.com/anthropics/flutter_document_capture/releases/download/${VERSION}"

# Check if frameworks already exist
OPENCV_DIR="$SCRIPT_DIR/Frameworks/opencv2.framework"

download_file() {
    local url=$1
    local output=$2

    echo "Downloading: $url"
    if command -v curl &> /dev/null; then
        curl -L -o "$output" "$url"
    elif command -v wget &> /dev/null; then
        wget -O "$output" "$url"
    else
        echo "Error: curl or wget is required"
        exit 1
    fi
}

# Download and extract opencv2.framework
if [ ! -d "$OPENCV_DIR" ]; then
    echo "Downloading opencv2.framework..."
    OPENCV_ZIP="$SCRIPT_DIR/opencv2.framework.zip"
    download_file "${BASE_URL}/opencv2.framework.zip" "$OPENCV_ZIP"

    if [ -f "$OPENCV_ZIP" ]; then
        mkdir -p "$SCRIPT_DIR/Frameworks"
        unzip -q -o "$OPENCV_ZIP" -d "$SCRIPT_DIR/Frameworks/"
        rm -f "$OPENCV_ZIP"
        echo "opencv2.framework extracted successfully"
    fi
else
    echo "opencv2.framework already exists"
fi

echo "All iOS dependencies ready!"
