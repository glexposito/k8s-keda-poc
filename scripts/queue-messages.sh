#!/usr/bin/env bash
# Manage the local Azurite queue through the existing Compose CLI image.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  queue-messages.sh add AMOUNT [QUEUE]
  queue-messages.sh remove AMOUNT [QUEUE]
  queue-messages.sh count [QUEUE]

QUEUE defaults to core-workers-queue. AMOUNT must be a positive integer.
add creates the queue if needed and appends AMOUNT demo messages.
remove permanently deletes up to AMOUNT currently visible messages.
count reads the approximate total, including invisible messages.

Examples:
  ./scripts/queue-messages.sh add 100
  ./scripts/queue-messages.sh remove 95
  ./scripts/queue-messages.sh count

Start Azurite with docker compose up -d azurite before using this script.
EOF
}

fail_usage() {
  printf 'Error: %s\n\n' "$1" >&2
  usage >&2
  exit 2
}

action="${1:-}"
amount=0
queue=core-workers-queue
case "$action" in
  -h|--help)
    usage
    exit 0
    ;;
  add|remove)
    [[ $# -ge 2 && $# -le 3 ]] || fail_usage "$action requires AMOUNT and an optional QUEUE."
    [[ "$2" =~ ^[1-9][0-9]*$ ]] || fail_usage 'AMOUNT must be a positive integer.'
    amount="$2"
    queue="${3:-$queue}"
    ;;
  count)
    [[ $# -le 2 ]] || fail_usage 'count accepts only an optional QUEUE.'
    queue="${2:-$queue}"
    ;;
  *)
    fail_usage 'Choose add, remove, or count.'
    ;;
esac

# Override the seed entrypoint so this never runs the automatic 100-message seed.
# RPM-based Azure CLI images keep their bundled SDK outside Python's normal path.
exec docker compose -f "$REPO_ROOT/docker-compose.yaml" run --rm --no-deps -T \
  --entrypoint /bin/sh queue-seed -ec '
    python_cmd=python3
    if command -v python3.12 >/dev/null 2>&1; then python_cmd=python3.12; fi
    for sdk_path in /usr/lib*/az/lib/python*/site-packages /opt/az/lib/python*/site-packages; do
      if [ -d "$sdk_path/azure/storage/queue" ]; then
        export PYTHONPATH="$sdk_path${PYTHONPATH:+:$PYTHONPATH}"
        break
      fi
    done
    exec "$python_cmd" - "$@"
  ' queue-messages "$action" "$amount" "$queue" <<'PY'
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
PY
