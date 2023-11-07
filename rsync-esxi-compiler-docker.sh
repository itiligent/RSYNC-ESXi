#!/bin/bash
# To install Docker in Debian:
# sudo apt-get update && sudo apt install curl docker.io python3 python3-pip -y
# sudo usermod -aG docker $USER
# Next START A NEW TERMIANL and run this script as sudo (new terminal refreshes Docker group permissions):
# sudo ./rsync-esxi-compiler-docker.sh

clear
docker build . -t rsync-esxi
docker run -d --name rsync-esxi rsync-esxi /bin/bash -c "while true; do sleep 30; done;"
docker cp rsync-esxi:/rsync/rsync ~/.
chmod 755 ~/rsync
docker stop rsync-esxi
clear
echo "If build was successful, below output should state: 'not a dynamic executable:'"
ldd ~/rsync
echo
echo "Testing new rsync binary..."
echo
cd ~ && ./rsync -V
echo
echo "The new rsync binary is located in the current dir."