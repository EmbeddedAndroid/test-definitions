#!/bin/bash

# Execute the command and store the output
output=$(dmesg | grep iommu)

# Check if the output is empty
if [ -z "$output" ]; then
    echo "dmesg-iommu FAIL"
else
    echo "dmesg-iommu PASS"
fi
