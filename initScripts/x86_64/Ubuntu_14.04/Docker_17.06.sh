#!/bin/bash
set -e
set -o pipefail

# initScript for Ubuntu 16.04 and Docker 17.06
# ------------------------------------------------------------------------------

readonly DOCKER_VERSION="17.06.0"
readonly SWAP_FILE_PATH="/root/.__sh_swap__"
export docker_restart=false
export install_docker_only="$install_docker_only"

if [ -z "$install_docker_only" ]; then
  install_docker_only="false"
fi

check_init_input() {
  local expected_envs=(
    'NODE_SHIPCTL_LOCATION'
    'NODE_ARCHITECTURE'
    'NODE_OPERATING_SYSTEM'
    'LEGACY_CI_CEXEC_LOCATION_ON_HOST'
    'SHIPPABLE_RELEASE_VERSION'
    'SHIPPABLE_AMI_VERSION'
    'EXEC_IMAGE'
    'REQKICK_DIR'
    'IS_SWAP_ENABLED'
    'REQKICK_DOWNLOAD_URL'
    'CEXEC_DOWNLOAD_URL'
    'REPORTS_DOWNLOAD_URL'
  )

  check_envs "${expected_envs[@]}"
}

create_shippable_dir() {
  create_dir_cmd="mkdir -p /home/shippable"
  exec_cmd "$create_dir_cmd"
}

install_docker_prereqs() {
  echo "Installing docker prerequisites"

  update_cmd="apt-get update"
  exec_cmd "$update_cmd"

  install_prereqs_cmd="apt-get -yy install apt-transport-https git python-pip software-properties-common ca-certificates curl wget tar linux-image-extra-virtual linux-image-extra-`uname -r`"
  exec_cmd "$install_prereqs_cmd"

  add_docker_repo_keys='curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -'
  exec_cmd "$add_docker_repo_keys"

  add_docker_repo='add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"'
  exec_cmd "$add_docker_repo"

  update_cmd="apt-get update"
  exec_cmd "$update_cmd"
}

install_prereqs() {
  echo "Installing prerequisite binaries"

  pushd /tmp
  echo "Installing node 4.8.5"

  get_node_tar_cmd="wget https://nodejs.org/dist/v4.8.5/node-v4.8.5-linux-x64.tar.xz"
  exec_cmd "$get_node_tar_cmd"

  node_extract_cmd="tar -xf node-v4.8.5-linux-x64.tar.xz"
  exec_cmd "$node_extract_cmd"

  node_copy_cmd="cp -Rf node-v4.8.5-linux-x64/{bin,include,lib,share} /usr/local"
  exec_cmd "$node_copy_cmd"

  check_node_version_cmd="node -v"
  exec_cmd "$check_node_version_cmd"
  popd

  echo "Installing shipctl components"
  exec_cmd "$NODE_SHIPCTL_LOCATION/$NODE_ARCHITECTURE/$NODE_OPERATING_SYSTEM/install.sh"

  exec_cmd "$update_cmd"
}

check_swap() {
  echo "Checking for swap space"

  swap_available=$(free | grep Swap | awk '{print $2}')
  if [ $swap_available -eq 0 ]; then
    echo "No swap space available, adding swap"
    is_swap_required=true
  else
    echo "Swap space available, not adding"
  fi
}

add_swap() {
  echo "Adding swap file"
  echo "Creating Swap file at: $SWAP_FILE_PATH"
  add_swap_file="touch $SWAP_FILE_PATH"
  exec_cmd "$add_swap_file"

  swap_size=$(cat /proc/meminfo | grep MemTotal | awk '{print $2}')
  swap_size=$(($swap_size/1024))
  echo "Allocating swap of: $swap_size MB"
  initialize_file="dd if=/dev/zero of=$SWAP_FILE_PATH bs=1M count=$swap_size"
  exec_cmd "$initialize_file"

  echo "Updating Swap file permissions"
  update_permissions="chmod -c 600 $SWAP_FILE_PATH"
  exec_cmd "$update_permissions"

  echo "Setting up Swap area on the device"
  initialize_swap="mkswap $SWAP_FILE_PATH"
  exec_cmd "$initialize_swap"

  echo "Turning on Swap"
  turn_swap_on="swapon $SWAP_FILE_PATH"
  exec_cmd "$turn_swap_on"

}

check_fstab_entry() {
  echo "Checking fstab entries"

  if grep -q $SWAP_FILE_PATH /etc/fstab; then
    exec_cmd "echo /etc/fstab updated, swap check complete"
  else
    echo "No entry in /etc/fstab, updating ..."
    add_swap_to_fstab="echo $SWAP_FILE_PATH none swap sw 0 0 | tee -a /etc/fstab"
    exec_cmd "$add_swap_to_fstab"
    exec_cmd "echo /etc/fstab updated"
  fi
}

initialize_swap() {
  check_swap
  if [ "$is_swap_required" == true ]; then
    add_swap
  fi
  check_fstab_entry
}

docker_install() {
  echo "Installing docker"

  install_docker="apt-get install -q --force-yes -y -o Dpkg::Options::='--force-confnew' docker-ce=$DOCKER_VERSION~ce-0~ubuntu"
  exec_cmd "$install_docker"

  get_static_docker_binary="wget https://download.docker.com/linux/static/stable/x86_64/docker-$DOCKER_VERSION-ce.tgz -P /tmp/docker"
  exec_cmd "$get_static_docker_binary"

  extract_static_docker_binary="tar -xzf /tmp/docker/docker-$DOCKER_VERSION-ce.tgz --directory /opt"
  exec_cmd "$extract_static_docker_binary"

  remove_static_docker_binary='rm -rf /tmp/docker'
  exec_cmd "$remove_static_docker_binary"
}

check_docker_opts() {
  # SHIPPABLE docker options required for every node
  echo "Checking docker options"

  SHIPPABLE_DOCKER_OPTS='DOCKER_OPTS="$DOCKER_OPTS -H unix:///var/run/docker.sock -g=/data"'
  opts_exist=$(sh -c "grep '$SHIPPABLE_DOCKER_OPTS' /etc/default/docker || echo ''")

  # DOCKER_OPTS do not exist or match.
  if [ -z "$opts_exist" ]; then
    echo "Removing existing DOCKER_OPTS in /etc/default/docker, if any"
    sed -i '/^DOCKER_OPTS/d' "/etc/default/docker"

    echo "Appending DOCKER_OPTS to /etc/default/docker"
    sh -c "echo '$SHIPPABLE_DOCKER_OPTS' >> /etc/default/docker"
    docker_restart=true
  else
    echo "Shippable docker options already present in /etc/default/docker"
  fi

  ## remove the docker option to listen on all ports
  echo "Disabling docker tcp listener"
  sh -c "sed -e s/\"-H tcp:\/\/0.0.0.0:4243\"//g -i /etc/default/docker"
}

check_proxy_envs() {
  if [ ! -z "$SHIPPABLE_HTTP_PROXY" ]; then
    http_proxy_env="export http_proxy=\"$SHIPPABLE_HTTP_PROXY\""
    http_proxy_exists=$(grep "^$http_proxy_env$" /etc/default/docker || echo "")
    if [ -z "$http_proxy_exists" ]; then
      __process_msg "Configuring docker http_proxy"
      sed -i '/^export http_proxy/d' /etc/default/docker
      echo "$http_proxy_env" >> /etc/default/docker
      docker_restart=true
    fi
  else
    # Clean up any env configured already if we do not find it in our
    # environment
    http_proxy_exists=$(grep "^export http_proxy=" /etc/default/docker || echo "")
    if [ ! -z "$http_proxy_exists" ]; then
      __process_msg "Removing docker http_proxy"
      sed -i '/^export http_proxy/d' /etc/default/docker
      docker_restart=true
    fi
  fi

  if [ ! -z "$SHIPPABLE_HTTPS_PROXY" ]; then
    https_proxy_env="export https_proxy=\"$SHIPPABLE_HTTPS_PROXY\""
    https_proxy_exists=$(grep "^$https_proxy_env$" /etc/default/docker || echo "")
    if [ -z "$https_proxy_exists" ]; then
      __process_msg "Configuring docker https_proxy"
      sed -i '/^export https_proxy/d' /etc/default/docker
      echo "$https_proxy_env" >> /etc/default/docker
      docker_restart=true
    fi
  else
    # Clean up any env configured already if we do not find it in our
    # environment
    https_proxy_exists=$(grep "^export https_proxy=" /etc/default/docker || echo "")
    if [ ! -z "$https_proxy_exists" ]; then
      __process_msg "Removing docker https_proxy"
      sed -i '/^export https_proxy/d' /etc/default/docker
      docker_restart=true
    fi
  fi

  if [ ! -z "$SHIPPABLE_NO_PROXY" ]; then
    no_proxy_env="export no_proxy=\"$SHIPPABLE_NO_PROXY\""
    no_proxy_exists=$(grep "^$no_proxy_env$" /etc/default/docker || echo "")
    if [ -z "$no_proxy_exists" ]; then
      __process_msg "Configuring docker no_proxy"
      sed -i '/^export no_proxy/d' /etc/default/docker
      echo "$no_proxy_env" >> /etc/default/docker
      docker_restart=true
    fi
  else
    # Clean up any env configured already if we do not find it in our
    # environment
    no_proxy_exists=$(grep "^export no_proxy=" /etc/default/docker || echo "")
    if [ ! -z "$no_proxy_exists" ]; then
      __process_msg "Removing docker no_proxy"
      sed -i '/^export no_proxy/d' /etc/default/docker
      docker_restart=true
    fi
  fi
}

restart_docker_service() {
  echo "checking if docker restart is necessary"
  if [ $docker_restart == true ]; then
    echo "restarting docker service on reset"
    exec_cmd "service docker restart"
  else
    echo "docker_restart set to false, not restarting docker daemon"
  fi
}

install_ntp() {
  {
    check_ntp=$(service --status-all 2>&1 | grep ntp)
  } || {
    true
  }

  if [ ! -z "$check_ntp" ]; then
    echo "NTP already installed, skipping."
  else
    echo "Installing NTP"
    exec_cmd "apt-get install -y ntp"
    exec_cmd "service ntp restart"
  fi
}

fetch_cexec() {
  __process_marker "Fetching cexec..."
  local cexec_tar_file="cexec.tar.gz"

  if [ -d "$LEGACY_CI_CEXEC_LOCATION_ON_HOST" ]; then
    exec_cmd "rm -rf $LEGACY_CI_CEXEC_LOCATION_ON_HOST"
  fi
  rm -rf $cexec_tar_file
  pushd /tmp
    wget $CEXEC_DOWNLOAD_URL -O $cexec_tar_file
    mkdir -p $LEGACY_CI_CEXEC_LOCATION_ON_HOST
    tar -xzf $cexec_tar_file -C $LEGACY_CI_CEXEC_LOCATION_ON_HOST --strip-components=1
    rm -rf $cexec_tar_file
  popd

  # Download and extract reports bin file into a path that cexec expects it in
  local reports_dir="$LEGACY_CI_CEXEC_LOCATION_ON_HOST/bin"
  local reports_tar_file="reports.tar.gz"
  rm -rf $reports_dir
  mkdir -p $reports_dir
  pushd $reports_dir
    wget $REPORTS_DOWNLOAD_URL -O $reports_tar_file
    tar -xf $reports_tar_file
    rm -rf $reports_tar_file
  popd
}

pull_reqProc() {
  __process_marker "Pulling reqProc..."
  docker pull $EXEC_IMAGE
}

fetch_reqKick() {
  __process_marker "Fetching reqKick..."
  local reqKick_tar_file="reqKick.tar.gz"

  rm -rf $REQKICK_DIR
  rm -rf $reqKick_tar_file
  pushd /tmp
    wget $REQKICK_DOWNLOAD_URL -O $reqKick_tar_file
    mkdir -p $REQKICK_DIR
    tar -xzf $reqKick_tar_file -C $REQKICK_DIR --strip-components=1
    rm -rf $reqKick_tar_file
  popd
  pushd $REQKICK_DIR
    npm install
  popd
}

before_exit() {
  echo $1
  echo $2

  echo "Node init script completed"
}

main() {
  if [ "$install_docker_only" == "true" ]; then
    trap before_exit EXIT
    exec_grp "install_docker_prereqs"

    trap before_exit EXIT
    exec_grp "docker_install"

    trap before_exit EXIT
    exec_grp "check_docker_opts"

    trap before_exit EXIT
    exec_grp "check_proxy_envs"

    trap before_exit EXIT
    exec_grp "restart_docker_service"
  else
    check_init_input

    trap before_exit EXIT
    exec_grp "create_shippable_dir"

    trap before_exit EXIT
    exec_grp "install_docker_prereqs"

    trap before_exit EXIT
    exec_grp "install_prereqs"

    if [ "$IS_SWAP_ENABLED" == "true" ]; then
      trap before_exit EXIT
      exec_grp "initialize_swap"
    fi

    trap before_exit EXIT
    exec_grp "docker_install"

    trap before_exit EXIT
    exec_grp "check_docker_opts"

    trap before_exit EXIT
    exec_grp "check_proxy_envs"

    trap before_exit EXIT
    exec_grp "restart_docker_service"

    trap before_exit EXIT
    exec_grp "install_ntp"

    trap before_exit EXIT
    exec_grp "fetch_cexec"

    trap before_exit EXIT
    exec_grp "pull_reqProc"

    trap before_exit EXIT
    exec_grp "fetch_reqKick"
  fi
}

main
