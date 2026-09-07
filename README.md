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
- sudo, if your Docker data is owned by root (the usual case with rootful Docker)

# Usage

```bash
fly-to-podman.sh {containers|images|networks|volumes|full} [...]
        images: Migrate Docker images to Podman
        volumes: Migrate Docker volumes to Podman
        containers: Migrate Docker containers to Podman
        networks: Migrate Docker networks to Podman
        full: Migrate Docker containers, images, networks, and volumes to Podman.
```

You can specify multiple arguments to migrate only what you need:
- `./fly-to-podman.sh containers` - migrate only containers (existing flow)
- `./fly-to-podman.sh containers images` - migrate containers and
  images
- `./fly-to-podman.sh images networks` - migrate images and networks -
  or any other combination
- `./fly-to-podman.sh full` - migrate everything

Note: 'full' is mutually exclusive and cannot be combined with other
arguments. When combined with other arguments, the script will prefer
full over the other arguments. It will not fail, it will emit a
warning and migrate all supported objects

# Permissions

Run it as your normal user, not with `sudo`. Podman takes its storage from the user running it, so `sudo fly-to-podman.sh` migrates everything into root's storage and you end up with a rootful Podman setup instead of a rootless one.

Your user needs to be in the `docker` group to talk to the Docker daemon:

```bash
sudo usermod -aG docker "$USER"
```

Log out and back in afterwards so that the new group gets recognized.

The volumes data in `DockerRootDir` may be owned by root, so it is copied with `sudo rsync` and chowned to your user.

# Issues and contributions

If you find any issues or have any suggestions, please open an issue or a pull request.
