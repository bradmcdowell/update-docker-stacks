# Update All Stacks

This script update all stacks on a docker host

1: Install cron if it doesn't exist

```
sudo apt update && sudo apt install -y cron
sudo systemctl enable --now cron
crontab -e
```

2: Create a crontab job

```
5 2 * * * /home/<YOUR_USERNAME>/update-docker-stacks/update_all_stacks.sh
```
