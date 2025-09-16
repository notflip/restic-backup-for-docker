## Restic backup for Coolify docker volumes

```
cp restic.env.example restic.env
# Configure restic.env
cd
apt install bzip2 -y
curl -LO https://github.com/restic/restic/releases/download/v0.18.0/restic_0.18.0_linux_amd64.bz2
bzip2 -d restic_0.18.0_linux_amd64.bz2
chmod +x restic_0.18.0_linux_amd64
sudo mv restic_0.18.0_linux_amd64 /usr/local/bin/restic
```

## Crontab

- add to cronbtab `0 1 * * * cd /root/restic && /bin/bash ./restic-backup.sh >> /var/log/restic-backup.log 2>&1`

## Running

```
./restic-cmd.sh init` # to init new repository (make sure the last segment of the url is okay in the .env)
./restic-backup.sh # to test
./restic-cmd.sh snapshots # to test after backing up
```
