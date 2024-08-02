Role Name
=========

This role was used to upgrade Proxmox PVE version 7 to 8.
This is a in place upgrade for Proxmox clusters.

This will stop running vms (if used in production please schedule downtime)

Requirements
------------

Please note it is required to have Idrac access to the hosts you are performing upgrades on, this is best practise, please see troubleshooting for reasons.

- Ansible 2.9 or higher
- Proxmox VE 7.x installed
- SSH access to Proxmox VE hosts with sudo privileges
- Idrac access to proxmox host

Role Variables
--------------

The role vairables are created from a bash script, and are stored in vars/vc_main.yml

This role has been created to run with expressions in the command line -e target_host="hostname"

Dependencies
------------

There are no dependancies this uses purely ansible builtin modules

Example Playbook
----------------

- name: Upgrade Proxmox VE from 7 to 8
  hosts: "{{ target-host }}"
  become: true
  roles:
    - pve_upgrade

It is very advisable to run this playbook like this:

ansible-playbook pve7to8.yml -e target_host="hostname" --tags "pre_flight,apt_update_tweak"

and then After completing the above steps and performing the upgrade via the Proxmox GUI or iDRAC, run the following to continue with the reboot:

ansible-playbook pve7to8.yml -e target_host="hostname" --tags "reboot"

Please replace hostname with the inventory hostname thats in ~/ansible/inventory Please also only run this against one host at a time.

It is important to note that this role will stop all running vms on a given host.

It is also advisable to change the vms options to restart after rebbot: No on the proxmox gui, due to issues found in troubleshooting.

-------
Troubleshooting:
-------

There are certain makes of servers that when upgrading the debian version changes the interface naming:

example:

eno1 will cahnge to eno1np0
eno2 will change to eno2np1

in /etc/network/interfaces

by default the role changes the interface names to the correct debian 6 version type. 

But I have found that sometimes the new kernel version sticks to the orginal naming, therefore the host will become offline, 
The fix is to use the idrac, login to the box and check the network interfaces:

Run: to check the network interfaces types 
root% ip a 

If eno1 and eno2 are being used, reverse the change ansible did:

root% sed -i 's/eno1np0/eno1/g' /etc/networking/interfaces  
root% sed -i 's/eno2np1/eno2/g' /etc/networking/interfaces

Then restart the network interfaces:

root% systemctl restart networking.services

-------
Tasks
-------

Pre-flight Checks:
  Copies and executes get_vmid.sh script.
  Fetches and backs up configuration files.
  Moves backup files to /tmp/.
  Apt Update Tweak:

Stops the specified VMs.
  Updates GRUB and waits for completion.
  Ensures no apt-get processes are running.
  Removes leftover lock files.
  Upgrades and updates apt packages.
  Replaces "bullseye" and "buster" with "bookworm" in apt sources.
  Updates the apt package index.
  Reboot and Check (optional):

Runs the pve7to8 checker installer script.
  Checks for upgrade failures.
  Updates network configuration.
  Upgrades the OS using apt-get dist-upgrade.
  Reboots the system and waits for SSH to become available.
  Checks and prints Proxmox VE status.


License
-------

MIT

Author Information
------------------

Author: Darren Lavery

