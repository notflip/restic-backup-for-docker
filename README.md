- `cp config.yml.example config.yml`
- Configure config.yml
- `snap install yq`
- `snap install restic --classic`
- add to cronbtab `sudo crontab -e` (`0 1 * * * /root/restic/restic-backup.sh`)
- or run `./restic-backup.sh` to test straight away
run `./restic-cmd.sh snapshots` to confirm the snapshot is backed up