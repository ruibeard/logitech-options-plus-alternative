#!/usr/bin/env python3
"""Show executable disk sizes and measured macOS physical footprint / RSS."""
import ctypes
import argparse
import os
import pathlib
import struct
import subprocess
import time
import tempfile
import plistlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / 'build/MX Mouse Settings.app'
HELPER = APP / 'Contents/Library/LoginItems/MX Mouse Helper.app/Contents/MacOS/mxmouse-helper'
LIB = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)


def measure(pid, label):
    data = ctypes.create_string_buffer(1024)
    if LIB.proc_pid_rusage(pid, 2, ctypes.byref(data)):
        raise OSError(ctypes.get_errno(), f'Cannot measure PID {pid}')
    resident, footprint = struct.unpack_from('QQ', data.raw, 64)
    print(f'{label}: physical footprint {footprint / 1048576:.2f} MiB; RSS {resident / 1048576:.2f} MiB')
    return footprint


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--samples', type=int, default=1, help='Number of live-helper samples, 0.5 seconds apart.')
    parser.add_argument('--max-footprint-mib', type=float, help='Fail if any sampled helper physical footprint exceeds this ceiling.')
    parser.add_argument('--require-connected', type=int, default=0, help='Require at least this many connected mice in the current helper snapshot.')
    arguments = parser.parse_args()
    if arguments.samples < 1 or arguments.samples > 120 or arguments.require_connected < 0:
        parser.error('Use 1–120 samples and a nonnegative connected-mouse count.')
    if arguments.max_footprint_mib is not None and not (0 < arguments.max_footprint_mib < float('inf')):
        parser.error('The physical-footprint ceiling must be finite and positive.')
    print('Executable sizes on disk (not RAM):')
    for label, path in [('Helper', HELPER), ('Settings', APP / 'Contents/MacOS/mxmouse-settings')]:
        print(f'  {label}: {path.stat().st_size:,} bytes')
    helper_pids = subprocess.run(['pgrep', '-x', 'mxmouse-helper'], capture_output=True, text=True).stdout.split()
    readings = []
    if helper_pids:
        path = pathlib.Path.home() / 'Library/Application Support/MX Mouse/status.plist'
        try:
            snapshot = plistlib.loads(path.read_bytes())
        except (OSError, plistlib.InvalidFileException):
            snapshot = {}
        current = str(snapshot.get('pid', '')) in helper_pids
        count = snapshot.get('connectedCount', int(bool(snapshot.get('connected')))) if current else 0
        print(f'Current helper snapshot: {count} connected mice.' if current else 'No status snapshot for the running helper.')
        for device in snapshot.get('devices', []) if current else []:
            print(f"  {device.get('name', 'Unknown mouse')}: {device.get('state', 'unknown')} ({device.get('transport', 'unknown transport')})")
        if count < arguments.require_connected:
            raise SystemExit(f'Connected-device measurement needs {arguments.require_connected} mice; current snapshot reports {count}.')
        for sample in range(arguments.samples):
            for pid in helper_pids:
                readings.append(measure(int(pid), f'Running helper, sample {sample + 1}'))
            if sample + 1 < arguments.samples:
                time.sleep(0.5)
    else:
        if arguments.require_connected:
            raise SystemExit('No running helper; connected-device measurement cannot proceed.')
        print('Measuring offline helper; no HID access or connected-mouse workload.')
        with tempfile.TemporaryDirectory(prefix="mx-measure-") as directory:
            (pathlib.Path(directory) / "Library/Application Support").mkdir(parents=True)
            process = subprocess.Popen([str(HELPER), '--offline', '--duration', '4'], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
                                       env=dict(os.environ, HOME=directory))
            try:
                time.sleep(0.7)
                if process.poll() is not None:
                    raise RuntimeError(process.stderr.read().strip())
                readings.append(measure(process.pid, 'Offline helper'))
            finally:
                if process.poll() is None:
                    process.terminate()
                _, error = process.communicate(timeout=10)
                if process.returncode:
                    raise RuntimeError(error)
    settings_pids = subprocess.run(['pgrep', '-x', 'mxmouse-settings'], capture_output=True, text=True).stdout.split()
    for pid in settings_pids:
        measure(int(pid), 'Settings open')
    if not settings_pids:
        print('Settings closed: no Settings process running.')
    if arguments.max_footprint_mib is not None and max(readings, default=float('inf')) > arguments.max_footprint_mib * 1048576:
        raise SystemExit(f'Helper exceeds the approved {arguments.max_footprint_mib:g} MiB physical-footprint ceiling.')


if __name__ == '__main__':
    main()
