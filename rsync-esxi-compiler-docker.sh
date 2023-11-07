#!/bin/bash
# To install Docker:
# sudo apt-get update && sudo apt install curl docker.io python3 python3-pip -y 
# sudo usermod -aG docker $USER
# Start a NEW terminal session and run this script (new terminal refreshes Docker group permissions) 
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
echo "The new rsync binary is located in the home dir."
