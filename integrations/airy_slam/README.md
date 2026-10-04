# Optional Airy-SLAM integration

These are the relevant changes made in the separate Airy-SLAM project.
`airy.patch` is based on Airy commit
`1c950955f149ed35c5bb554010b77874ca25850b`. It modifies the Rust gamma receiver,
state, recording/replay and UI to consume Red Pitaya batches without applying
Sigma50 energy calibration. The new Rust parser is included separately.

Apply to a compatible, clean Airy checkout, after checking the patch:

```sh
# Run in your Airy-SLAM checkout; set this to this MCA checkout's absolute path.
MCA_REPO=/path/to/red_pitaya_4ch_mca
git apply --check "$MCA_REPO/integrations/airy_slam/airy.patch"
git apply "$MCA_REPO/integrations/airy_slam/airy.patch"
cp "$MCA_REPO/integrations/airy_slam/gamma_rs/src/redpitaya.rs" gamma_rs/src/
cp "$MCA_REPO/integrations/airy_slam/compose.redpitaya.yaml" .
cp "$MCA_REPO/integrations/airy_slam/scripts/"*.sh scripts/
mkdir -p docker/redpitaya redpitaya
cp "$MCA_REPO/integrations/airy_slam/docker/redpitaya/Dockerfile" docker/redpitaya/
cp "$MCA_REPO/redpitaya/reader.py" "$MCA_REPO/redpitaya/README.md" redpitaya/
cp -R "$MCA_REPO/redpitaya/board" "$MCA_REPO/redpitaya/bitstream" redpitaya/
```

Add `redpitaya/runtime/` and `redpitaya/captures/` to the Airy `.gitignore` before
creating credentials or collecting data. Configure its dedicated SSH key,
pinned host key and optional connection.env as described in the root README.
The supplied overlay expects Airy's CycloneDDS configuration, Sigma50 base
image, gamma Dockerfile and sibling `psl-api` checkout. They are dependencies of
Airy; the standalone MCA receiver does not require them.

```sh
bash scripts/start_redpitaya.sh --channels 1,2,3,4
bash scripts/stop_redpitaya.sh
```

The integration combines accepted events for gross mapping, retains each
channel’s raw 9-word record and source epoch in reduced NPZ output, and includes
raw events/status/counts in ROS recordings. It keeps Sigma50's original driver
and calibration separate. Coincidence matching is not implemented here.

`tests/ros_smoke.py` is an isolated ROS + gamma application check: use a separate
ROS domain and test UI port, as stated in its docstring. Airy's Rust tests and
four-channel synthetic replay were exercised on the Radxa during development.
