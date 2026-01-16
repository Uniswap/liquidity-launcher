#!/bin/bash
ROOT=$(git rev-parse --show-toplevel)

# Build the address miner
cd $ROOT/test/saltGenerator/addressMiner
cargo build --release
cd $ROOT