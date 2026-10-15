#!/usr/bin/env python3
"""Show executable disk sizes and measured macOS physical footprint / RSS."""
import ctypes
import os
import pathlib
import struct
import subprocess
import time
import tempfile

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


def main():
    print('Executable sizes on disk (not RAM):')
    for label, path in [('Helper', HELPER), ('Settings', APP / 'Contents/MacOS/mxmouse-settings')]:
        print(f'  {label}: {path.stat().st_size:,} bytes')
    helper_pids = subprocess.run(['pgrep', '-x', 'mxmouse-helper'], capture_output=True, text=True).stdout.split()
    if helper_pids:
        for pid in helper_pids:
            measure(int(pid), 'Running helper (connection state not checked)')
    else:
        print('Measuring offline helper; no HID access or connected-mouse workload.')
        with tempfile.TemporaryDirectory(prefix="mx-measure-") as directory:
            (pathlib.Path(directory) / "Library/Application Support").mkdir(parents=True)
            process = subprocess.Popen([str(HELPER), '--offline', '--duration', '4'], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
                                       env=dict(os.environ, HOME=directory))
            try:
                time.sleep(0.7)
                if process.poll() is not None:
                    raise RuntimeError(process.stderr.read().strip())
                measure(process.pid, 'Offline helper')
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


if __name__ == '__main__':
    main()
