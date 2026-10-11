#!/bin/bash
# test-p2-int: the runner's per-step time limit, end to end (runner-1001/bounded.sh). This step ends at once; its row
# (scripts/checks-manifest.d/int-gaps.tsv) gives it a 20 s limit. The mutation row timeout-toy-hang
# (scripts/mutations.d/int-gaps.tsv) makes it hang in a child that ignores TERM: runner-1001/mutate.sh must then report
# it CAUGHT as "TIMEOUT runner-timeout-toy" about 25 s later (TERM, then KILL to its process group), not wait it out.
echo "PASS the toy step starts"
echo "PASS the toy step ends by itself"
