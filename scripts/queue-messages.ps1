#!/usr/bin/env pwsh
# Manage the local Azurite queue through the existing Compose CLI image.
# Requires PowerShell 7+ (pwsh) - Windows PowerShell 5.1's older native
# argument passing mangles the embedded double quotes in $ShWrapper below.

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot

function Show-Usage {
    @'
Usage:
  queue-messages.ps1 add AMOUNT [QUEUE]
  queue-messages.ps1 remove AMOUNT [QUEUE]
  queue-messages.ps1 count [QUEUE]

QUEUE defaults to core-workers-queue. AMOUNT must be a positive integer.
add creates the queue if needed and appends AMOUNT demo messages.
remove permanently deletes up to AMOUNT currently visible messages.
count reads the approximate total, including invisible messages.

Examples:
  ./scripts/queue-messages.ps1 add 100
  ./scripts/queue-messages.ps1 remove 95
  ./scripts/queue-messages.ps1 count

Start Azurite with docker compose up -d azurite before using this script.
'@
}

function Fail-Usage {
    param([string]$Message)
    [Console]::Error.WriteLine("Error: $Message`n")
    [Console]::Error.WriteLine((Show-Usage))
    exit 2
}

$action = if ($args.Count -ge 1) { $args[0] } else { "" }
$amount = 0
$queue = "core-workers-queue"

switch ($action) {
    { $_ -in "-h", "--help" } {
        Show-Usage
        exit 0
    }
    { $_ -in "add", "remove" } {
        if ($args.Count -lt 2 -or $args.Count -gt 3) {
            Fail-Usage "$action requires AMOUNT and an optional QUEUE."
        }
        if ($args[1] -notmatch '^[1-9][0-9]*$') {
            Fail-Usage "AMOUNT must be a positive integer."
        }
        $amount = $args[1]
        if ($args.Count -ge 3) { $queue = $args[2] }
        break
    }
    "count" {
        if ($args.Count -gt 2) {
            Fail-Usage "count accepts only an optional QUEUE."
        }
        if ($args.Count -ge 2) { $queue = $args[1] }
        break
    }
    default {
        Fail-Usage "Choose add, remove, or count."
    }
}

# Override the seed entrypoint so this never runs the automatic 100-message seed.
# RPM-based Azure CLI images keep their bundled SDK outside Python's normal path.
$ShWrapper = @'
python_cmd=python3
if command -v python3.12 >/dev/null 2>&1; then python_cmd=python3.12; fi
for sdk_path in /usr/lib*/az/lib/python*/site-packages /opt/az/lib/python*/site-packages; do
  if [ -d "$sdk_path/azure/storage/queue" ]; then
    export PYTHONPATH="$sdk_path${PYTHONPATH:+:$PYTHONPATH}"
    break
  fi
done
exec "$python_cmd" - "$@"
'@

$PythonScript = @'
import os
import sys
import uuid

from azure.core.exceptions import AzureError, ResourceExistsError
from azure.storage.queue import QueueClient

action, amount, queue_name = sys.argv[1:]
amount = int(amount)
completed = 0

try:
    with QueueClient.from_connection_string(
        os.environ["AZURE_STORAGE_CONNECTION_STRING"],
        queue_name,
        api_version="2023-11-03",
        retry_total=0,
        connection_timeout=5,
        read_timeout=15,
    ) as queue:
        if action == "add":
            try:
                queue.create_queue()
            except ResourceExistsError:
                pass
            run_id = uuid.uuid4().hex
            for index in range(1, amount + 1):
                queue.send_message(f"message-{run_id}-{index}")
                completed += 1
            print(f"Added {completed} messages to {queue_name}.", flush=True)
        elif action == "remove":
            while completed < amount:
                # Limit each fetch to the remaining amount so retained messages
                # are not made invisible by fetching more than we will delete.
                batch_size = min(32, amount - completed)
                messages = list(queue.receive_messages(
                    messages_per_page=batch_size,
                    max_messages=batch_size,
                    visibility_timeout=300,
                ))
                if not messages:
                    break
                for message in messages:
                    queue.delete_message(message)
                    completed += 1
            print(f"Removed {completed} of {amount} requested messages from {queue_name}.", flush=True)
            if completed < amount:
                print("No more visible messages are available.", flush=True)

        count = queue.get_queue_properties().approximate_message_count
        print(f"{queue_name}: approximately {count} messages.")
except AzureError as error:
    print(f"Error: {error}", file=sys.stderr)
    if action != "count":
        print(f"{action}: {completed} message operations confirmed before the error.", file=sys.stderr)
    sys.exit(1)
'@

$PythonScript | & docker compose -f "$RepoRoot/docker-compose.yaml" run --rm --no-deps -T `
    --entrypoint /bin/sh queue-seed -ec $ShWrapper queue-messages $action $amount $queue

exit $LASTEXITCODE
