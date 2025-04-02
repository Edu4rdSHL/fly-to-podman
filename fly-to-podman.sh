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
    # Get the path to the Podman volumes directory (and guess at the Docker volumes directory)
    PODMAN_VOLUMES_PATH=$(podman info --format json | jq -r '.store.volumePath')
    DOCKER_VOLUMES_PATH=$(docker system info -fjson | jq -r '.DockerRootDir')/volumes

    RSYNC_OPTS=""
    if [[ "$UID" -ne 0 ]]; then
        # If not running as root, make sure to chown the files to the current user
        RSYNC_OPTS+=" --chown=$(id -u):$(id -g)"
    fi

    for volume in $(docker volume ls --format json | jq -r '.Name'); do
        echo "Migrating volume: $volume"
        podman volume create "$volume" &&
            sudo rsync -a "$RSYNC_OPTS" "$DOCKER_VOLUMES_PATH/$volume/_data/" "$PODMAN_VOLUMES_PATH/$volume/_data"
    done
}

# Migrate networks
migrate_networks() {
    echo "Migrating Docker networks to Podman..."

    # Get all Docker networks
    for network in $(docker network ls --format '{{json . }}' | jq -r '.Name'); do
        echo "Processing network: $network"

        # Skip default Docker networks
        if [[ "$network" == "host" || "$network" == "none" ]]; then
            echo "Skipping network: $network (Podman does not need it)"
            continue
        fi

        # Extract network details
        NETWORK_JSON=$(docker network inspect "$network" | jq '.[0]')
        DRIVER=$(echo "$NETWORK_JSON" | jq -r '.Driver')
        SUBNET=$(echo "$NETWORK_JSON" | jq -r '.IPAM.Config[0].Subnet // empty')
        GATEWAY=$(echo "$NETWORK_JSON" | jq -r '.IPAM.Config[0].Gateway // empty')
        IP_RANGE=$(echo "$NETWORK_JSON" | jq -r '.IPAM.Config[0].IPRange // empty')

        # Check if the network already exists in Podman
        if podman network exists "$network"; then
            echo "Network $network already exists in Podman. Skipping creation."
            continue
        fi

        # Build the Podman network create command
        PODMAN_NET_CMD="podman network create"

        # Add driver (Podman supports `bridge`, `ipvlan` and `macvlan`)
        case "$DRIVER" in
        "bridge")
            PODMAN_NET_CMD+=" --driver bridge"
            ;;
        "macvlan")
            PODMAN_NET_CMD+=" --driver macvlan"
            ;;
        "ipvlan")
            PODMAN_NET_CMD+=" --driver ipvlan"
            ;;
        *)
            echo "Warning: Unsupported network driver '$DRIVER' in Podman. Using default bridge."
            PODMAN_NET_CMD+=" --driver bridge"
            ;;
        esac

        # Add subnet configuration if available
        if [[ -n "$SUBNET" ]]; then
            PODMAN_NET_CMD+=" --subnet $SUBNET"
        fi

        # Add gateway if available
        if [[ -n "$GATEWAY" ]]; then
            PODMAN_NET_CMD+=" --gateway $GATEWAY"
        fi

        # Add IP range if available
        if [[ -n "$IP_RANGE" ]]; then
            PODMAN_NET_CMD+=" --ip-range $IP_RANGE"
        fi

        # Finalize the command with network name
        PODMAN_NET_CMD+=" $network"

        # Create the Podman network
        echo "Creating Podman network: $network"
        eval "$PODMAN_NET_CMD" && echo "Network $network migrated successfully." ||
            echo "Failed to migrate network: $network"

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

        # Extract port mappings
        PORT_OPTS=""
        while read -r port_mapping; do
            HOST_IP=$(echo "$port_mapping" | jq -r '.HostIp')
            HOST_PORT=$(echo "$port_mapping" | jq -r '.HostPort')
            CONTAINER_PORT=$(echo "$port_mapping" | jq -r '.ContainerPort')
            PROTOCOL=$(echo "$port_mapping" | jq -r '.Protocol')

            # Construct `-p` option (exclude 0.0.0.0 for readability)
            if [[ "$HOST_IP" == "0.0.0.0" || -z "$HOST_IP" ]]; then
                PORT_OPTS+=" -p $HOST_PORT:$CONTAINER_PORT/$PROTOCOL"
            else
                PORT_OPTS+=" -p $HOST_IP:$HOST_PORT:$CONTAINER_PORT/$PROTOCOL"
            fi
        done < <(docker inspect "$container" | jq -c '.[] | .NetworkSettings.Ports | to_entries[] | {ContainerPort: .key, Protocol: (if .key | contains("udp") then "udp" else "tcp" end), HostMappings: .value} | select(.HostMappings != null) | .HostMappings[] | {HostIp, HostPort, ContainerPort, Protocol}')

        # Extract network information
        NETWORK_OPTS=""
        while read -r network; do
            NETWORK_NAME=$(echo "$network" | jq -r 'keys[0]')
            NETWORK_IP=$(echo "$network" | jq -r ".$NETWORK_NAME.IPAddress")

            if [[ -n "$NETWORK_NAME" ]]; then
                NETWORK_OPTS+=" --network=$NETWORK_NAME"
            fi

            if [[ -n "$NETWORK_IP" ]]; then
                NETWORK_OPTS+=" --ip=$NETWORK_IP"
            fi
        done < <(docker inspect "$container" | jq -c '.[0].NetworkSettings.Networks')

        # Run the container with the same name and mounts, including RW/RO options
        podman run -d --name "$container" $PODMAN_RESTART "$MOUNT_OPTS" "$PORT_OPTS" "$NETWORK_OPTS" "$MIGRATION_CONTAINER_TAG" &&
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
networks)
    migrate_networks
    ;;
full)
    migrate_images
    migrate_volumes
    migrate_networks
    migrate_containters
    ;;
*)
    echo "Usage: $0 {images|volumes|containers|full}"
    echo -e "\timages: Migrate Docker images to Podman"
    echo -e "\tvolumes: Migrate Docker volumes to Podman"
    echo -e "\tcontainers: Migrate Docker containers to Podman"
    echo -e "\tnetworks: Migrate Docker networks to Podman"
    echo -e "\tfull: Migrate Docker images, volumes, and containers to Podman"
    exit 1
    ;;
esac
