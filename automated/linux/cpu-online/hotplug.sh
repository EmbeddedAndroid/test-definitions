#!/bin/sh

# shellcheck disable=SC1091

. automated/lib/sh-test-lib
OUTPUT="$(pwd)/automated/linux/cpu-online/output"
RESULT_FILE="${OUTPUT}/result.txt"

export RESULT_FILE

check_cpu_status() {
    cat /sys/devices/system/cpu/cpu*/online
}

offline_cpu() {
    echo 0 > "/sys/devices/system/cpu/$1/online"
}

online_cpu() {
    echo 1 > "/sys/devices/system/cpu/$1/online"
}

echo "Initial CPU status:"
check_cpu_status

test_passed=true
for cpu in /sys/devices/system/cpu/cpu[0-7]*; do
    cpu_id=$(basename "$cpu")
    

    echo "Offlining $cpu_id"
    offline_cpu "$cpu_id"
    sleep 1
    

    online_status=$(cat /sys/devices/system/cpu/$cpu_id/online)
    if [ "$online_status" -ne 0 ]; then
        echo "Failed to offline $cpu_id"
        test_passed=false
    fi
    

    echo "Onlining $cpu_id"
    online_cpu "$cpu_id"
    sleep 1
    

    online_status=$(cat /sys/devices/system/cpu/$cpu_id/online)
    if [ "$online_status" -ne 1 ]; then
        echo "Failed to online $cpu_id"
        test_passed=false
    fi
done

create_out_dir "${OUTPUT}"

info_msg "Final CPU status:"
check_cpu_status
TCID="CPU_Hotplug_Test"
# Print overall test result
if [ "$test_passed" = true ]; then
    echo "CPU hotplug TEST PASSED"
    info_msg "CPU hotplug TEST PASSED."
    report_pass "${TCID}"
else
    echo "CPU hotplug TEST FAILED."
    info_msg "CPU hotplug TEST FAILED."
    report_fail "${TCID}"
fi