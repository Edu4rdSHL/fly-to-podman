# fly-to-podman
Migrate from Docker to Podman.

fly-to-podman is a small bash script that helps you migrate from Docker to Podman. It will migrate your Docker containers, images, and volumes to Podman, as well as keep your container data and configurations (mounts, ports, etc.) intact.

Full blog post: [From Docker to Podman: full migration to rootless](https://www.edu4rdshl.dev/posts/from-docker-to-podman-full-migration-to-rootless/)

# What it does

- Migrate Docker images to Podman (including tags)
- Migrate Docker volumes to Podman (including all data)
- Migrate Docker networks to Podman (including names, IPs, gateways, IP ranges, etc.)
- Migrate Docker containers to Podman (including names, IDs, and statuses such as restart policy, etc.)
- Keep container data and configurations (mounts, exposed ports, etc.)

# Requirements

- Docker
- Podman
- bash
- jq
- rsync

# Usage

```bash
fly-to-podman.sh {images|volumes|containers|full}
        images: Migrate Docker images to Podman
        volumes: Migrate Docker volumes to Podman
        containers: Migrate Docker containers to Podman
        networks: Migrate Docker networks to Podman
        full: Migrate Docker images, volumes, and containers to Podman
```

# Issues and contributions

If you find any issues or have any suggestions, please open an issue or a pull request.
