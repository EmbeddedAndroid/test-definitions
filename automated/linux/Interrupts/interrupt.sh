#!/bin/sh

. automated/lib/sh-test-lib

OUTPUT="$(pwd)/automated/linux/Interrupts/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE

# Function to get the timer count
get_timer_count() {
    cat /proc/interrupts | grep arch_timer
}

# Get the initial timer count
echo "Initial timer count:"
initial_count=$(get_timer_count)
echo "$initial_count"

# Wait for 2 minutes
sleep 120

# Get the timer count after 2 minutes
echo "Timer count after 2 minutes:"
final_count=$(get_timer_count)
echo "$final_count"

create_out_dir "${OUTPUT}"
TCID="Interrupts_Test"

# Compare the initial and final counts
echo "Comparing timer counts:"
echo "$initial_count" | while read -r line; do
    cpu=$(echo "$line" | awk '{print $1}')
    initial_values=$(echo "$line" | awk '{for(i=2;i<=9;i++) print $i}')
    final_values=$(echo "$final_count" | grep "$cpu" | awk '{for(i=2;i<=9;i++) print $i}')
    
    fail_test=false
    initial_values_list=$(echo "$initial_values" | tr ' ' '\n')
    final_values_list=$(echo "$final_values" | tr ' ' '\n')
    
    i=0
    echo "$initial_values_list" | while read -r initial_value; do
        final_value=$(echo "$final_values_list" | sed -n "$((i+1))p")
        if [ "$initial_value" -lt "$final_value" ]; then
            echo "CPU $i: Timer count has incremented. Test PASSED" | tee -a "${RESULT_FILE}"
        else
            echo "CPU $i: Timer count has not incremented. Test FAILED" | tee -a "${RESULT_FILE}"
            fail_test=true
        fi
        i=$((i+1))
    done
	echo $fail_test
    if [ "$fail_test" = false ]; then
        echo "Interrupt TEST PASSED"
        info_msg "Interrupt TEST PASSED."
        report_pass "${TCID}"
    else
        echo "Interrupt TEST FAILED."
        info_msg "Interrupt TEST FAILED."
        report_fail "${TCID}"
    fi
done
