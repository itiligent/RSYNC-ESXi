# RSYNC for ESXi
### Build script for compiling rsync for use with VMware ESXi
Rsync is a mature Linux staple for reliably replicating files over imperfect or lower speed links. For data migration it is particularly useful for keeping track of data changes between systems during a staged cutover, but it is equally useful as a backup and disaster recovery tool.

## Requirements:
- **A centos 7 virtual machine**
  - Download a Centos 7 ISO here: http://isoredirect.centos.org/centos/7/isos/x86_64/
- **A Centos 7 user account with sudo administrator rights**


## Build Instructions
You can build your own rsync binary with the [included build script](https://raw.githubusercontent.com/itiligent/RSYNC-for-ESXi/main/rsync-esxi-builder.sh), or you can [download rsync v3.2.7 for ESXi prebuilt](https://github.com/itiligent/RSYNC-for-ESXi/raw/main/rsync)

  
    1. Copy the build script to your Centos 7 home directory
    2. Make build script executable: chmod +x rsync-builder-centos7.sh
    3. Run the build script (don't run as sudo, it will prompt for sudo): ./rsync-builder-centos7.sh
    4. Copy the new rync binary to a *persistent* location in ESXi (e.g. a VMFS datastore or /productLocker/ are good locations) 
    5. Set execute permissions on rsync: chmod 744 rsync

## ESXi rsync examples:
### rsync via SSH (prompts for destination's password):
```
/productLocker/rsync -avurP --delete --progress /vmfs/volumes/source_path/* user@x.x.x.x:/destination_path/
```
### rsync via SSH with SSHkey authentication (no password prompt)

- SSH keys can be used to enable rsync to non interactively authenticate to the destination. Save the destination's private SSH key to a file in a *persistent* location and change the file's permissions with: `chmod 400 priv-key.txt` The below example uses SSH key auth to automatically login and begin sync (no password or other ssh prompts):
```
/productLocker/rsync -avurP --delete --progress -e "ssh -i /productLocker/priv-key.txt -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" /vmfs/volumes/source_path/* user@x.x.x.x:/destination_path/
```

### rsync to a local USB Datastore
Note: rsync over USB can be slower than over the network. See [here for instructions on adding a USB VMFS backup datastore](https://github.com/itiligent/ESXi-Custom-ISO/blob/main/homelab-cheat-sheet.md#to-add-a-usb-backup-datastore-to-esxi)

    1. Establish a USB VMFS backup datastore
    2. Create a backup destination folder on the USB datastore e.g. mkdir /vmfs/volumes/USB_datastore/full_backup
    3. Modify the below command to suit:
    
    /vmfs/volumes/USB_destination_datastore/rsync -rltDv --delete --progress /vmfs/volumes/source_path/* /vmfs/volumes/USB_datastore/destination_path

This repo was collacted and updated from a wide range of ineternet sources, none of which were complete or working. A revised selection of development package selections and changes to their specific install order solved all issues.     
