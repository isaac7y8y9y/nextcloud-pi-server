#!/usr/bin/env python3
"""Exercise real maintenance guards with streamed output and producer failures."""

import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
PRODUCER = r'''
import signal, sys, time
signal.signal(signal.SIGPIPE, signal.SIG_DFL)
print("  - installed: true")
print("  - maintenance: " + sys.argv[1], flush=True)
time.sleep(0.1)
sys.stdout.write("  - needsDbUpgrade: false\n  - productname: fixture\n" * 16384)
sys.stdout.flush()
sys.exit(int(sys.argv[2]))
'''
PRELUDE = '''set -euo pipefail
NEXTCLOUD_APP_CONTAINER=fixture-app
fixture_producer() { python3 -c "$PRODUCER" "$STATE" "$PRODUCER_EXIT"; }
remote() { fixture_producer; }
die() { return 1; }
'''


def exercise(label: str, body: str, expected: str) -> int:
    for state, producer_exit, accept in (
        (expected, 0, True),
        ("false" if expected == "true" else "true", 0, False),
        (expected, 7, False),
    ):
        env = dict(os.environ, PRODUCER=PRODUCER, STATE=state,
                   PRODUCER_EXIT=str(producer_exit))
        result = subprocess.run(["bash", "-c", PRELUDE + body], env=env,
                                capture_output=True, timeout=10)
        if (result.returncode == 0) != accept:
            raise SystemExit(f"{label}: state={state}, producer_exit={producer_exit}, "
                             f"expected_accept={accept}, actual_exit={result.returncode}")
    return 3


def main() -> None:
    helper = ROOT / "privileged/nextcloud-pi-ops"
    guards = [(line_number, line.strip()) for line_number, line in
              enumerate(helper.read_text().splitlines(), 1)
              if "/usr/bin/docker exec --user www-data" in line
              and "php /var/www/html/occ status | /usr/bin/grep" in line]
    if not guards:
        raise SystemExit("No privileged streamed maintenance guards were exercised")
    cases = 0
    for line_number, line in guards:
        expected = "true" if "*true$" in line else "false"
        body = line.replace("/usr/bin/docker", "fixture_producer").replace(
            '"${P[NEXTCLOUD_PI_APP_CONTAINER]}"', '"fixture-app"')
        cases += exercise(f"privileged guard at line {line_number}", body, expected)
    backup = (ROOT / "scripts/backup-runtime-state.sh").read_text()
    for name, expected in (("maintenance_is_on", "true"), ("maintenance_is_off", "false")):
        match = re.search(r"^" + name + r"\(\) \{\n.*?^\}", backup, re.M | re.S)
        if not match:
            raise SystemExit(f"Runtime backup guard {name} is missing")
        body = match.group(0) + f"\nif {name}; then exit 0; else exit 1; fi\n"
        cases += exercise(f"runtime backup {name}", body, expected)
    print(f"Streamed maintenance guard tests passed: {cases} behavioral cases")


if __name__ == "__main__":
    main()
