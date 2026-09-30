#!/usr/bin/env bash
# Provisions the orun runner image (github-runner.pkr.hcl). Runs as root.
#
# Mirrors what orun-cloud lanes expect from GitHub's ubuntu-latest image:
# a `runner` user with home /home/runner (DOCKER_CONFIG and orun's shared
# caches are hard-coded there), passwordless sudo, docker, node 20 and 22 in
# the hosted tool cache, pnpm via corepack, the Playwright/Chromium system
# libraries, and the AWS CLI the module's start script uses.
set -euo pipefail

cloud-init status --wait || true

# Boot speed: nothing may take the dpkg lock or phone home at first boot.
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service motd-news.timer || true
systemctl mask apt-daily.service apt-daily-upgrade.service || true
apt-get -y purge unattended-upgrades ubuntu-advantage-tools update-notifier-common || true

apt-get -y update
apt-get -y upgrade
apt-get -y install --no-install-recommends \
  ca-certificates curl gnupg lsb-release jq git git-lfs unzip zip xz-utils \
  build-essential python3 python3-pip rsync openssh-client libicu74 acl

# Docker CE (buildx + compose plugins, as on hosted runners)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get -y update
apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable docker.service containerd.service

# AWS CLI v2 (the start script reads its JIT config from SSM)
curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip

# runner user, same shape as the hosted image
useradd --create-home --home-dir /home/runner --shell /bin/bash runner
usermod -aG docker runner
echo "runner ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/runner
chmod 0440 /etc/sudoers.d/runner
install -d -o runner -g runner /home/runner/.docker /home/runner/.orun/actions/shared
# The hosted runner's work layout: jobs run in /home/runner/work/<repo>/<repo>.
# actions/cache stores paths outside the workspace RELATIVE to it, so a cache
# saved on a GitHub-hosted runner holds ../../../.local/bin/orun and restores
# into the wrong place under /opt/actions-runner/_work. The runner's _work is a
# symlink to /home/runner/work: `..` resolves physically, and every cache
# shared with hosted runners lands where the job expects it.
install -d /home/runner/work /opt/actions-runner
ln -sfn /home/runner/work /opt/actions-runner/_work

# install -d owns only the leaf: hand the whole home to runner, or a lane's
# `mkdir ~/.orun/tool-cache` is refused (orun-cloud CI).
chown -R runner:runner /home/runner

# Node in the hosted tool cache: setup-node resolves these without a download,
# and orun-cloud links $RUNNER_TOOL_CACHE/node into each lane's tool cache.
mkdir -p /opt/hostedtoolcache/node
for v in ${NODE_VERSIONS}; do
  dest=/opt/hostedtoolcache/node/$v/x64
  mkdir -p "$dest"
  curl -fsSL "https://nodejs.org/dist/v$v/node-v$v-linux-x64.tar.xz" | tar -xJ -C "$dest" --strip-components=1
  touch "/opt/hostedtoolcache/node/$v/x64.complete"
done
latest=$(ls /opt/hostedtoolcache/node | sort -V | tail -1)
for bin in node npm npx corepack; do
  ln -sf "/opt/hostedtoolcache/node/$latest/x64/bin/$bin" "/usr/local/bin/$bin"
done
corepack enable --install-directory /usr/local/bin

# Chromium's system libraries for Playwright. The browser binary itself comes
# from orun-cloud's Playwright cache, keyed on the locked version.
npx --yes playwright@latest install-deps chromium

# Trim boot work: the fleet has no use for these.
systemctl disable --now snapd.snap-repair.timer 2>/dev/null || true
systemctl disable ubuntu-advantage.service 2>/dev/null || true

apt-get -y autoremove
apt-get clean
