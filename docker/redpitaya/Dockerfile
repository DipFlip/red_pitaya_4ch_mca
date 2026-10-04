ARG ROS_DISTRO=jazzy
FROM ros:${ROS_DISTRO}-ros-base
SHELL ["/bin/bash", "-c"]
RUN apt-get update && apt-get install -y --no-install-recommends openssh-client \
    ros-${ROS_DISTRO}-rmw-cyclonedds-cpp && rm -rf /var/lib/apt/lists/*
COPY redpitaya/reader.py /opt/redpitaya/reader.py
COPY redpitaya/board/readout.py redpitaya/board/wire.py /opt/redpitaya/board/
CMD ["python3", "/opt/redpitaya/reader.py"]
