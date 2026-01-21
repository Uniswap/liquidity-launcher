#!/bin/bash

# Run the address miner with given inputs
ROOT=$(git rev-parse --show-toplevel)

$ROOT/test/saltGenerator/addressMiner/target/release/address-miner $@