#!/bin/bash

# Execute the command and store the output
output=$(ls /sys/kernel/debug/pinctrl)

# Check if the output is empty
if [ -z "$output" ]; then
	echo "msm-pinctrl FAIL"
else
	echo "msm-pinctrl PASS"
fi
