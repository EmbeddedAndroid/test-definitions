#!/bin/sh

. automated/lib/sh-test-lib
OUTPUT="$(pwd)/automated/linux/Video/output"
RESULT_FILE="${OUTPUT}/result.txt"

export RESULT_FILE

create_out_dir "${OUTPUT}"

TCID="Video_Decode_Test"

# Make the test executable
chmod -R 777 /Video

# Run the first test
/Video/iris_v4l2_test --config /Video/DEC_AVC_NV12_BASIC_CFG.json --loglevel 15 >> video_dec.txt

if grep -q "Test Passed" "video_dec.txt"; then
  echo "Video Decode Test Passed"
  info_msg "TEST PASSED."
  report_pass "${TCID}"
else
  echo "Video Decode Test Failed"
  info_msg "TEST FAILED."
  report_fail "${TCID}"
fi