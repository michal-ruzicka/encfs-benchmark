#!/bin/bash

sudo ./encfs-benchmark.pl working-dir/run* |& tee "${0}".log
