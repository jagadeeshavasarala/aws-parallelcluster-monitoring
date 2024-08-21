#!/bin/bash

apt-get -y install golang-go

curl -fsSL https://get.docker.com | sh

curl -L "https://github.com/docker/compose/releases/download/v2.29.1/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg &&
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' |
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list &&
    apt-get update &&
    apt-get install -y nvidia-container-toolkit &&
    nvidia-ctk runtime configure --runtime=docker