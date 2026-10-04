FROM --platform=linux/amd64 ubuntu:22.04@sha256:b1066385161d28ddf6bc7e7b28a9170eec11484c821d1a5150d176cbde41d7f7
ENV DEBIAN_FRONTEND=noninteractive LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates build-essential git python3 python3-numpy iverilog \
    locales lsb-release file unzip libtinfo5 libncurses5 libx11-6 libxext6 \
    libxrender1 libxtst6 libxi6 libxft2 libgtk2.0-0 libglib2.0-0 libssl3 \
    libnss3 libasound2 zlib1g xvfb && \
    locale-gen en_US.UTF-8 && rm -rf /var/lib/apt/lists/*
# The proprietary AMD tool is mounted at /tools, never copied into this image.
WORKDIR /work
CMD ["bash"]
