#!/bin/bash

# Define the output file
output_file="/root/vc_main.yml"

# Initialize the YAML content
echo "---" > $output_file
echo "vmid:" >> $output_file

# Get the list of running VMs and append their VMIDs to the output file
qm list | awk '$3 == "running" {print "  - " $1}' >> $output_file

echo "YAML output saved to $output_file"
