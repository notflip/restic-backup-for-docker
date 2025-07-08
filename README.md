- `cp config.yml.example config.yml`
- Configure config.yml
- `snap install yq`

apt install bzip2 -y
curl -LO https://github.com/restic/restic/releases/download/v0.18.0/restic-0.18.0.tar.gz
tar xf restic-0.18.0.tar.gz 
chmod +x restic-0.18.0/
sudo mv restic-0.18.0 /usr/local/bin/restic

- add to cronbtab `0 1 * * * cd /root/restic && /bin/bash ./restic-backup.sh >> /var/log/restic-backup.log 2>&1`
- or run `./restic-backup.sh` to test straight away
run `./restic-cmd.sh snapshots` to confirm the snapshot is backed up

## Configure Restic
- Use the volume names (as seen in persistent storage in Coolify)