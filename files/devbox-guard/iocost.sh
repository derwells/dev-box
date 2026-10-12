#!/bin/sh
# Enable blk-iocost on every real disk. With the `none`/`mq-deadline`
# schedulers the kernel ignores io.weight entirely, so without this the
# IOWeight= settings on ssh, tailscaled and fleet.slice do nothing.
for d in /sys/block/sd* /sys/block/vd* /sys/block/nvme*n*; do
  [ -e "$d/dev" ] || continue
  echo "$(cat "$d/dev") enable=1" > /sys/fs/cgroup/io.cost.qos || true
done
