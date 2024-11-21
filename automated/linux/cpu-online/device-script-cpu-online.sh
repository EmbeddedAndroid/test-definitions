i#!/bin/bash

# Get the number of CPUs
cpu_count=$(cat /sys/devices/system/cpu/cpu*/online | wc -l)

# Function to check CPU status
check_cpu_status() {
	    local cpu=$1
	        cat /sys/devices/system/cpu/cpu$cpu/online
	}

# Function to set CPU status
set_cpu_status() {
	    local cpu=$1
	        local status=$2
		    echo $status > /sys/devices/system/cpu/cpu$cpu/online
	    }

    # Loop through each CPU and test enabling and disabling
    for ((cpu=0; cpu<cpu_count; cpu++)); do
	        echo "Testing CPU$cpu..."

		    # Disable CPU
		        set_cpu_status $cpu 0
			    sleep 1
			        if [ $(check_cpu_status $cpu) -eq 0 ]; then
					        echo "CPU$cpu successfully disabled."
						    else
							            echo "Failed to disable CPU$cpu."
								            exit 1
									        fi

										    # Enable CPU
										        set_cpu_status $cpu 1
											    sleep 1
											        if [ $(check_cpu_status $cpu) -eq 1 ]; then
													        echo "CPU$cpu successfully enabled."
														    else
															            echo "Failed to enable CPU$cpu."
																            exit 1
																	        fi
																	done

																	echo "All CPUs tested successfully."
