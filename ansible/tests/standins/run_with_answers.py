#!/usr/bin/env python3
"""Run ansible-playbook in a pseudo-terminal and answer its prompts.

Usage: run_with_answers.py [--approve ANSWER] [--confirm ANSWER] -- ansible-playbook ARGS...

The precheck review is answered with ANSWER (default APPROVE) and each "type YES" prompt
with the --confirm answer (default YES), so a stand-in run can go end to end. Needs pexpect.
"""
import sys

import pexpect

args = sys.argv[1:]
approve, confirm = 'APPROVE', 'YES'
while args and args[0] != '--':
    opt, val = args[0], args[1]
    if opt == '--approve':
        approve = val
    elif opt == '--confirm':
        confirm = val
    args = args[2:]
args = args[1:]

child = pexpect.spawn(args[0], args[1:], encoding='utf-8', timeout=900, dimensions=(50, 250))
child.logfile_read = sys.stdout
while True:
    i = child.expect([r'type APPROVE to continue\s*:', r'type YES to continue\]?\s*:', pexpect.EOF])
    if i == 0:
        child.sendline(approve)
    elif i == 1:
        child.sendline(confirm)
    else:
        break
child.close()
sys.exit(child.exitstatus if child.exitstatus is not None else 1)
