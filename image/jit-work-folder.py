#!/usr/bin/env python3
"""Point a JIT runner config's work folder at /home/runner/work.

The fleet's scale-up lambda asks GitHub for a just-in-time runner config with
the default work folder, "_work", which the runner resolves under its install
root (/opt/actions-runner/_work). GitHub-hosted runners work in
/home/runner/work, and two things depend on that layout:

- actions/cache stores paths outside the workspace relative to it, so a cache
  saved on a hosted runner (~/.local/bin/orun, the pnpm store) holds
  ../../../<path> and only restores correctly three levels below /home/runner;
- actions/checkout v6 scopes its credentials with includeIf "gitdir:<path>",
  which git matches against the real path, so the workspace cannot be a
  symlink.

The JIT config is base64 JSON whose values are base64 file contents; the
.runner file carries "workFolder". Rewrite it and print the new config. On any
error, print the original config unchanged: the runner still works, only
hosted-saved caches miss.

usage: jit-work-folder <jitconfig>  ->  <jitconfig>
"""
import base64
import json
import sys

WORK_FOLDER = "/home/runner/work"


def rewrite(encoded: str) -> str:
    files = json.loads(base64.b64decode(encoded))
    runner = json.loads(base64.b64decode(files[".runner"]).decode("utf-8-sig"))
    runner["workFolder"] = WORK_FOLDER
    files[".runner"] = base64.b64encode(json.dumps(runner).encode()).decode()
    return base64.b64encode(json.dumps(files).encode()).decode()


def main() -> None:
    original = sys.argv[1]
    try:
        print(rewrite(original))
    except Exception as err:  # fail open: never block a runner from starting
        print(f"jit-work-folder: left the config unchanged ({err})", file=sys.stderr)
        print(original)


if __name__ == "__main__":
    main()
