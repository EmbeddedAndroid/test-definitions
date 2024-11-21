#!/bin/bash

# Execute the command and store the output
output=$(dmesg | grep smmu)

# Check if the output is empty
if [ -z "$output" ]; then
    echo "dmesg-smmu FAIL"
else
    echo "dmesg-smmu PASS"
fi
