# /etc/cron.d/intune-backup
0  1  * * 0  root  docker exec intune-backup pgbackrest --stanza=intune --type=full backup
0  1  * * 1-6 root docker exec intune-backup pgbackrest --stanza=intune --type=diff backup
0  */6 * * * root  docker exec intune-backup pgbackrest --stanza=intune --type=incr backup
0  5  * * 1  root  /opt/intune/scripts/verify-restore.sh   # monthly restore test
