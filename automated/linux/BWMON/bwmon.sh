#!/bin/sh

. automated/lib/sh-test-lib
OUTPUT="$(pwd)/automated/linux/BWMON/output"
RESULT_FILE="${OUTPUT}/result.txt"

export RESULT_FILE

create_out_dir "${OUTPUT}"

TCID="BWMON_Test"


extract_votes() {
  cat /sys/kernel/debug/interconnect/interconnect_summary | grep -i pmu | awk '{print $NF}'
}

echo "Initial vote check:"
initial_votes=$(extract_votes)
echo "$initial_votes"


echo "Running bw_mem tool..."
./bin/"${abi}"/bw_mem 4000000000 frd &

echo "Vote check while bw_mem tool is running:"
current_votes=$(extract_votes)
echo "$current_votes"

wait

echo "Final vote check:"
final_votes=$(extract_votes)
echo "$final_votes"

echo "Comparing votes..."
echo "Initial votes: $initial_votes"
echo "Final votes: $final_votes"

incremented=true
for i in $(seq 1 $(echo "$initial_votes" | wc -l)); do
  initial_vote=$(echo "$initial_votes" | sed -n "${i}p")
  final_vote=$(echo "$final_votes" | sed -n "${i}p")
  if [ "$final_vote" -le "$initial_vote" ]; then
    incremented=false
    echo "Vote did not increment for row $i: initial=$initial_vote, final=$final_vote"
  else
    echo "Vote incremented for row $i: initial=$initial_vote, final=$final_vote"
  fi
done

if $incremented; then
  info_msg "TEST PASSED."
  report_pass "${TCID}"
else
  info_msg "TEST FAILED."
  report_fail "${TCID}"
fi
