#!/bin/sh
. automated/lib/sh-test-lib
OUTPUT="$(pwd)/automated/linux/DSP_AudioPD/output"
RESULT_FILE="${OUTPUT}/result.txt"

export RESULT_FILE

# Make the test executable
chmod -R 777 /DSP_audioPD

export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/DSP_audioPD/libs/

cd /DSP_audioPD/bins/
./adsprpcd &
PID = $!

if [ -z "$PID" ]; then
  echo "Failed to start the binary"
  exit 1
else
  echo "Binary is running successfully"
fi

create_out_dir "${OUTPUT}"

TCID="AudioPD_Test"

check_stack_trace() {
	local pid = $1
	if cat /proc/$pid/stack 2>/dev/null | grep -q "do_sys_poll"
		return 0
	else 
		return 1
	fi
}


if check_stack_trace "$PID"; then
	echo "Test Passed"
	info_msg "TEST PASSED."
    report_pass "${TCID}"
else
	echo "Test Failed"
	info_msg "TEST FAILED."
    report_fail "${TCID}"
fi

if kill -0 "$PID" 2>/dev/null; then
	kill -9 "$PID"
	wait "$PID"
fi
