ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $1 -C "cd /tmp && mkdir dslr && cd dslr && gphoto2 --capture-image-and-download"
scp $1:/tmp/dslr/* .
ssh $1 -C "rm -rf /tmp/dslr"
lava-test-run-attach capt0000.jpg application/x-jpg
