#!/bin/bash
# Test all iDRAC functionality on a real system
# Usage: ./test_all_features.sh <idrac-ip> [username] [password]

# Default values
HOST=${1:-"192.168.1.120"}  # Replace with your iDRAC IP
USERNAME=${2:-"root"}       # Default username
PASSWORD=${3:-"calvin"}     # Default password

echo "Testing iDRAC functionality on $HOST"

# Run the standard test suite (safe)
idrac test:all --host=$HOST --username=$USERNAME --password=$PASSWORD

# For more verbose output:
# idrac test:all --host=$HOST --username=$USERNAME --password=$PASSWORD --verbose

# To include tests that could modify the system:
# idrac test:all --host=$HOST --username=$USERNAME --password=$PASSWORD --no-skip-destructive

# For minimal output (only shows errors and summary):
# idrac test:all --host=$HOST --username=$USERNAME --password=$PASSWORD --quiet 