#!/bin/sh

. automated/lib/sh-test-lib
OUTPUT="$(pwd)/automated/linux/Graphics/output"
RESULT_FILE="${OUTPUT}/result.txt"

export RESULT_FILE

create_out_dir "${OUTPUT}"

TCID="Graphics_Test"

cd /Graphics

cp -r a660_sqe.fw /lib/firmware/
cp -r a660_zap.mbn /lib/firmware/qcom/qcs6490/
cp -r a660_gmu.bin /lib/firmware/

# Clear dmesg logs
dmesg -c

cat /dev/dri/card0 &
OUTPUT=$(dmesg)

# Check if the file is created
if [ $OUTPUT == *"Loaded GMU firmware"* ]; then
	echo "Test Passed" | tee "${RESULT_FILE}"
	info_msg "TEST PASSED."
    report_pass "${TCID}"
else
    echo "Test failed."
	info_msg "TEST FAILED."
    report_fail "${TCID}"
fi