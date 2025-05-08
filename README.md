- `cp config.yml.example config.yml`
- Configure config.yml
- `snap install yq`
- `snap install restic --classic`
- add to cronbtab `0 1 * * * cd /root/restic && /bin/bash ./restic-backup.sh >> /var/log/restic-backup.log 2>&1`
- or run `./restic-backup.sh` to test straight away
run `./restic-cmd.sh snapshots` to confirm the snapshot is backed up

## Configure Restic
- Use the volume names (as seen in persistent storage in Coolify)