#!/bin/bash
set -euo pipefail
if grep -RInE 'fatalError\(|TODO:|FIXME:' TVerClient TVerClientTests; then
  echo 'Disallowed placeholder found' >&2
  exit 1
fi
echo 'Static lint passed'
