export TMPDIR=${TMPDIR:-/tmp}

sanitize_cgroups() {
  mkdir -p /sys/fs/cgroup
  mountpoint -q /sys/fs/cgroup || \
    mount -t tmpfs -o uid=0,gid=0,mode=0755 cgroup /sys/fs/cgroup

  mount -o remount,rw /sys/fs/cgroup

  sed -e 1d /proc/cgroups | while read sys hierarchy num enabled; do
    if [ "$enabled" != "1" ]; then
      # subsystem disabled; skip
      continue
    fi

    grouping="$(cat /proc/self/cgroup | cut -d: -f2 | grep "\\<$sys\\>")"
    if [ -z "$grouping" ]; then
      # subsystem not mounted anywhere; mount it on its own
      grouping="$sys"
    fi

    mountpoint="/sys/fs/cgroup/$grouping"

    mkdir -p "$mountpoint"

    # clear out existing mount to make sure new one is read-write
    if mountpoint -q "$mountpoint"; then
      umount "$mountpoint"
    fi

    mount -n -t cgroup -o "$grouping" cgroup "$mountpoint"

    if [ "$grouping" != "$sys" ]; then
      if [ -L "/sys/fs/cgroup/$sys" ]; then
        rm "/sys/fs/cgroup/$sys"
      fi

      ln -s "$mountpoint" "/sys/fs/cgroup/$sys"
    fi
  done
}

start_docker() {
  mkdir -p /var/log
  mkdir -p /var/run

  sanitize_cgroups

  # check for /proc/sys being mounted readonly, as systemd does
  if grep '/proc/sys\s\+\w\+\s\+ro,' /proc/mounts >/dev/null; then
    mount -o remount,rw /proc/sys
  fi

  local server_args=""

  for registry in $1; do
    server_args="${server_args} --insecure-registry ${registry}"
  done

  if [ -n "$2" ]; then
    server_args="${server_args} --registry-mirror=$2"
  fi

  docker daemon ${server_args} >/tmp/docker.log 2>&1 &
  echo $! > /tmp/docker.pid

  trap stop_docker EXIT

  sleep 1

  until docker info >/dev/null 2>&1; do
    echo waiting for docker to come up...
    sleep 1
  done
}

stop_docker() {
  local private_key_path=$TMPDIR/build-cache-private-key
  if [ -s $private_key_path ]; then
    kill $SSH_AGENT_PID
  fi

  local pid=$(cat /tmp/docker.pid)
  if [ -z "$pid" ]; then
    return 0
  fi

  kill -TERM $pid
  wait $pid
}

private_registry() {
  local repository="${1}"

  if echo "${repository}" | fgrep -q '/' ; then
    local registry="$(extract_registry "${repository}")"
    if echo "${registry}" | fgrep -q '.' ; then
      return 0
    fi
  fi

  return 1
}

extract_registry() {
  local repository="${1}"

  echo "${repository}" | cut -d/ -f1
}

extract_repository() {
  local long_repository="${1}"

  echo "${long_repository}" | cut -d/ -f2-
}

image_from_tag() {
  docker images --no-trunc "$1" | awk "{if (\$2 == \"$2\") print \$3}"
}

image_from_digest() {
  docker images --no-trunc --digests "$1" | awk "{if (\$3 == \"$2\") print \$4}"
}

docker_pull() {
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  NC='\033[0m' # No Color

  pull_attempt=1
  max_attempts=3
  while [ "$pull_attempt" -le "$max_attempts" ]; do
    printf "Pulling ${GREEN}%s${NC}" "$1"

    if [ "$pull_attempt" != "1" ]; then
      printf " (attempt %s of %s)" "$pull_attempt" "$max_attempts"
    fi

    printf "...\n"

    if docker pull "$1"; then
      printf "\nSuccessfully pulled ${GREEN}%s${NC}.\n\n" "$1"
      return
    fi

    echo

    pull_attempt=$(expr "$pull_attempt" + 1)
  done

  printf "\n${RED}Failed to pull image %s.${NC}" "$1"
  exit 1
}

load_pubkey() {
  local private_key_path=$TMPDIR/build-cache-private-key

  (jq -r '.source.build_cache.private_key // empty' < $1) > $private_key_path

  if [ -s $private_key_path ]; then
    chmod 0600 $private_key_path

    eval $(ssh-agent) >/dev/null 2>&1

    SSH_ASKPASS=/opt/resource/askpass.sh DISPLAY= ssh-add $private_key_path >/dev/null

    mkdir -p ~/.ssh
    cat > ~/.ssh/config <<EOF
StrictHostKeyChecking no
LogLevel quiet
EOF
    chmod 0600 ~/.ssh/config
  fi
}


extract_build_cache_host() {
  local build_cache_host_config=$(jq -r '.source.build_cache.host // ""' < $1)
  local build_cache_host=""
  if [ -n "$build_cache_host_config" ]; then
    build_cache_host="$build_cache_host_config"
  else
    echo "No build_cache host specified; detecting container host instead."
    build_cache_host=$(ip route | grep default | head -n1 | awk '{print $3}')
  fi
  echo "${build_cache_host}"
}

export_build_cache() {
  local build_cache_port=$(jq -r '.source.build_cache.port // "22"' < $1)
  local build_cache_user=$(jq -r '.source.build_cache.user // ""' < $1)
  local build_cache_private_key=$(jq -r '.source.build_cache.private_key // ""' < $1)
  local build_cache_remote_path=$(jq -r '.source.build_cache.remote_path // ""' < $1)
  local build_cache_host="$(extract_build_cache_host $1)"
  local repository=$(jq -r '.source.repository // ""' < $1)
  local tag_name="${2}"
  local image_id="${3}"

  if [ -n "${build_cache_host}" ] && [ -n "${build_cache_port}" ] && [ -n "${build_cache_user}" ] && [ -n "${build_cache_remote_path}" ]; then
    echo "Beginning docker save to preserve docker build cache."
    docker tag "$image_id" "${repository}:${tag_name}"
    start=`date +%s`
    docker save "${repository}:${tag_name}" $(docker history -q "${repository}:${tag_name}" | tail -n +2 | grep -v \<missing\> | tr '\n' ' ') "$image_id" > image-with-history.tar
    end=`date +%s`
    runtime=$((end-start))
    echo "Finished docker save in ${runtime} seconds"
    echo "Beginning scp of image with build cache to build cache server.."
    start=`date +%s`
    ssh ${build_cache_user}@${build_cache_host} -p ${build_cache_port} "mkdir -p ${build_cache_remote_path}/${repository}/${tag_name}"
    scp -P ${build_cache_port} image-with-history.tar ${build_cache_user}@${build_cache_host}:${build_cache_remote_path}/${repository}/${tag_name}
    end=`date +%s`
    runtime=$((end-start))
    echo "Finished scp of image to the build cache server in ${runtime} seconds"
    echo "Cleaning up saved build cache..."
    rm image-with-history.tar
    echo "Done."    
  fi
}

import_build_cache() {
  local build_cache_port=$(jq -r '.source.build_cache.port // "22"' < $1)
  local build_cache_user=$(jq -r '.source.build_cache.user // ""' < $1)
  local build_cache_private_key=$(jq -r '.source.build_cache.private_key // ""' < $1)
  local build_cache_remote_path=$(jq -r '.source.build_cache.remote_path // ""' < $1)
  local build_cache_host="$(extract_build_cache_host $1)"
  local repository=$(jq -r '.source.repository // ""' < $1)
  local tag_name="${2}"

  if [ -n "${build_cache_host}" ] && [ -n "${build_cache_port}" ] && [ -n "${build_cache_user}" ] && [ -n "${build_cache_remote_path}" ]; then
    echo "Checking if a build build cache image for repo ${repository} and tag ${tag_name} exists on the build cache server.."
    cache_exists="$(ssh ${build_cache_user}@${build_cache_host} -p ${build_cache_port} "/bin/bash -c 'if [ -f \"${build_cache_remote_path}/${repository}/${tag_name}/image-with-history.tar\" ]; then echo \"exists\"; else echo \"\"; fi'")"
    if [ -n "$cache_exists" ]; then
      echo "Build cache image exists; downloading it from build cache server."
      start=`date +%s`
      scp -P ${build_cache_port} ${build_cache_user}@${build_cache_host}:${build_cache_remote_path}/${repository}/${tag_name}/image-with-history.tar ./image-with-history.tar
      end=`date +%s`
      runtime=$((end-start))
      echo "Finished scp of image from the build cache server in ${runtime} seconds."
      echo "Performing docker load on the build cache image..."
      start=`date +%s`
      docker load -i image-with-history.tar
      end=`date +%s`
      runtime=$((end-start))
      echo "Build cache image loaded in ${runtime} seconds."
      echo "Removing build cache image.."
      rm image-with-history.tar
      echo "Build cache image removed."
    else
      echo "No build cache history exists; skipping cache load."
    fi
  fi
}