ARG ROS_DISTRO=jazzy
FROM airy-slam/sigma50:${ROS_DISTRO}
SHELL ["/bin/bash", "-c"]
RUN apt-get update && apt-get install -y --no-install-recommends openssh-client \
  && rm -rf /var/lib/apt/lists/*
COPY redpitaya/reader.py /opt/redpitaya/reader.py
COPY redpitaya/board/readout.py redpitaya/board/wire.py /opt/redpitaya/board/
# Inherit the existing ROS/CycloneDDS entrypoint; no USB privileges are needed.
CMD ["python3", "/opt/redpitaya/reader.py"]
