FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y \
        ffmpeg \
        curl \
        wget \
        jq \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# --- Piper TTS (background narration voice) ---
# Free, offline, neural TTS binary — no API key, no per-run cost.
RUN wget -q https://github.com/rhasspy/piper/releases/download/v1.2.0/piper_amd64.tar.gz -O /tmp/piper.tar.gz && \
    tar -xzf /tmp/piper.tar.gz -C /usr/local/bin --strip-components=1 && \
    rm /tmp/piper.tar.gz

# Voice model (~63MB) baked into the image so nothing needs to be
# downloaded at stream start — cached by the GitHub Actions build cache
# after the first build, same as everything else in this image.
RUN mkdir -p /app/voices && \
    wget -q -O /app/voices/en_US-lessac-medium.onnx \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx" && \
    wget -q -O /app/voices/en_US-lessac-medium.onnx.json \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json"

WORKDIR /app

# Copy the entire build context instead of naming files one by one.
# This automatically picks up everything the script can use — start.sh,
# overlay.png, font.ttf, galaxy_info.txt, facts.txt, and any per-video
# *.labels.txt / *.headlines.txt / *.facts.txt files — without needing
# a Dockerfile edit every time you add a new one.
COPY . .

RUN chmod +x start.sh

CMD ["./start.sh"]
