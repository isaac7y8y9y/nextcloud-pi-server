# Operations

These commands are intended for read-only checks on the Raspberry Pi. They do not upgrade, delete, or recreate anything.

Check containers:

```sh
sudo docker ps
sudo docker compose ps
```

Check Nextcloud status:

```sh
sudo docker exec --user www-data nextcloud-docker-app-1 php /var/www/html/occ status
sudo docker exec --user www-data nextcloud-docker-app-1 php /var/www/html/occ config:system:get datadirectory
```

Review logs:

```sh
sudo docker logs nextcloud-docker-app-1 --tail 100
sudo docker logs nextcloud-docker-db-1 --tail 100
sudo docker logs nextcloud-docker-caddy-1 --tail 100
```

Check storage:

```sh
findmnt /mnt/example-storage
df -h /mnt/example-storage
```

Check the Caddy route from the Mac:

```sh
curl -I https://cloud.example.invalid
```

If certificate trust is being diagnosed separately:

```sh
curl -k -I https://cloud.example.invalid
```

Do not paste authenticated headers, cookies, or token-bearing command output into documentation.

