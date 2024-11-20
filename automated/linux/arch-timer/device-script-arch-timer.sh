#!/bin/bash

# Function to get the numerical values from /proc/interrupts
get_values() {
	    cat /proc/interrupts | grep arch_timer | awk '{print $2, $3, $4, $5, $6, $7, $8, $9}'
}

# Get initial values
initial_values=$(get_values)

# Wait for 10 seconds
sleep 10

# Get new values
new_values=$(get_values)

# Check if all new values are greater than initial values
pass=true
for i in "${!initial_values[@]}"; do
	if [ ${new_values[$i]} -le ${initial_values[$i]} ]; then
		pass=false
		break
	fi
done

# Print result
if $pass; then
    echo "arch-timer PASS"
else
    echo "arch-timer FAIL"
fi
