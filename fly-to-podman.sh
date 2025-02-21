#!/bin/bash
# This script is used to migrate from Docker to Podman

# Migrate images
migrate_images() {
    echo "Migrating Docker images to Podman..."
    # Get a list of all Docker images (name:tag)
    docker images --format "{{.Repository}}:{{.Tag}}" | while read -r image; do
        # Skip <none>:<none> images
        if [[ "$image" == "<none>:<none>" ]]; then
            continue
        fi

        # Replace slashes in repository names with underscores for filenames
        filename=$(echo "$image" | tr '/' '_').tar

        echo "Exporting $image..."
        docker save -o "$filename" "$image" &&
            podman load -i "$filename" &&
            echo "Image $image migrated to Podman" || echo "Failed to migrate image $image"

        # Remove temporary file
        rm -f "$filename"
    done
}

# Migrate volumes
migrate_volumes() {
    echo "Migrating Docker volumes to Podman..."
    # Get the path to the Podman volumes directory
    PODMAN_VOLUMES_PATH=$(podman info --format json | jq -r '.store.volumePath')
    DOCKER_VOLUMES_PATH="/var/lib/docker/volumes"

    for volume in $(docker volume ls --format json | jq -r '.Name'); do
        echo "Migrating volume: $volume"
        podman volume create "$volume" &&
            sudo rsync -a "$DOCKER_VOLUMES_PATH/$volume/_data/" "$PODMAN_VOLUMES_PATH/$volume/_data"
    done
}

# Migrate containers
migrate_containters() {
    echo "Migrating Docker containers to Podman..."
    for container in $(docker container ls -a --format json | jq -r '.Names'); do
        # Convert container name to lowercase
        container_lc=$(echo "$container" | tr '[:upper:]' '[:lower:]')
        # Tag for the image to be created from the container
        MIGRATION_CONTAINER_TAG="podman.local/${container_lc}-to-podman:latest"
        # Get Running status from Docker
        WAS_RUNNING=$(docker container inspect -f '{{.State.Running}}' "$container")
        # Get RestartPolicy from Docker
        RESTART_POLICY=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$container")

        # Pass the restart policy to Podman
        case "$RESTART_POLICY" in
        "no") PODMAN_RESTART="" ;;
        "always") PODMAN_RESTART="--restart=always" ;;
        "unless-stopped") PODMAN_RESTART="--restart=unless-stopped" ;;
        "on-failure") PODMAN_RESTART="--restart=on-failure" ;;
        *) PODMAN_RESTART="" ;;
        esac

        echo "Processing container: $container"

        # Commit container to an image. It lets us start a new container with the _same_ state and add additional options
        docker commit "$container" "$MIGRATION_CONTAINER_TAG" &&
            docker save -o "$container_lc".tar "$MIGRATION_CONTAINER_TAG" &&
            podman load -i "$container_lc".tar || {
            echo "Failed to migrate image for $container"
            continue
        }

        # Extract volume/bind mount information from Docker container
        MOUNT_OPTS=""
        while read -r mount; do
            MOUNT_TYPE=$(echo "$mount" | jq -r '.Type')
            SOURCE=$(echo "$mount" | jq -r '.Source')
            DESTINATION=$(echo "$mount" | jq -r '.Destination')
            READ_WRITE=$(echo "$mount" | jq -r '.RW')

            # Pass the RW/RO setting to Podman
            if [[ "$READ_WRITE" == "true" ]]; then
                MODE="rw"
            else
                MODE="ro"
            fi

            if [[ "$MOUNT_TYPE" == "volume" ]]; then
                # Use :U to ensure right permissions inside the container.
                # It tells Podman to use the correct host UID and GID based on the UID and GID within the <<container|pod>>
                MODE+=",U"
                # Attach existing named volume
                VOLUME_NAME=$(echo "$mount" | jq -r '.Name')
                MOUNT_OPTS+=" -v $VOLUME_NAME:$DESTINATION:$MODE"
            elif [[ "$MOUNT_TYPE" == "bind" ]]; then
                # Use :Z if you're using SELinux to ensure right permissions inside the container
                # MODE+=",Z"
                # Ensure the source path exists before mounting
                [[ -e "$SOURCE" ]] && MOUNT_OPTS+=" -v $SOURCE:$DESTINATION:$MODE"
            fi
        done < <(docker inspect "$container" | jq -c '.[0].Mounts[]')

        # Run the container with the same name and mounts, including RW/RO options
        podman run -d --name "$container" $PODMAN_RESTART "$MOUNT_OPTS" "$MIGRATION_CONTAINER_TAG" &&
            echo "Container $container migrated successfully" ||
            echo "Failed to migrate container: $container"

        # Stop the container if this was not running, this allow us to keep the container ready to `podman container start $container`
        if [[ "$WAS_RUNNING" == "false" ]]; then
            podman stop "$container"
        fi
    done
}

# Process arguments
case "$1" in
images)
    migrate_images
    ;;
volumes)
    migrate_volumes
    ;;
containers)
    migrate_containters
    ;;
full)
    migrate_images
    migrate_volumes
    migrate_containters
    ;;
*)
    echo "Usage: $0 {images|volumes|containers|full}"
    echo -e "\timages: Migrate Docker images to Podman"
    echo -e "\tvolumes: Migrate Docker volumes to Podman"
    echo -e "\tcontainers: Migrate Docker containers to Podman"
    echo -e "\tfull: Migrate Docker images, volumes, and containers to Podman"
    exit 1
    ;;
esac
