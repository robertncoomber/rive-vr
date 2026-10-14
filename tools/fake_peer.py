#!/usr/bin/env python3
"""A fake player for testing local multiplayer with one headset.

Broadcasts the same packets the app does (UDP port 47777, the Wi-Fi subnet's
broadcast address): a head circling in front of the spawn point with its
hands waving. It also listens and prints a line whenever a headset's packets
arrive, so you can check both directions.

With --follow (the default) it hovers 1 m in front of the first headset it
hears, facing it, so it is always in view.

Usage: fake_peer.py [--interface en0] [--seconds 600] [--no-follow]
"""

import argparse
import math
import random
import re
import socket
import struct
import subprocess
import time

PORT = 47777
MAGIC = 0x31525652  # "RVR1"
PACKET = struct.Struct('<III21f')


def broadcast_address(interface):
    out = subprocess.run(['ifconfig', interface], capture_output=True, text=True).stdout
    match = re.search(r'broadcast (\d+\.\d+\.\d+\.\d+)', out)
    return match.group(1) if match else '255.255.255.255'


def yaw_quat(yaw):
    return (0.0, math.sin(yaw / 2), 0.0, math.cos(yaw / 2))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--interface', default='en0')
    parser.add_argument('--seconds', type=float, default=600)
    parser.add_argument('--no-follow', dest='follow', action='store_false')
    args = parser.parse_args()

    target = broadcast_address(args.interface)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(('', PORT))
    sock.setblocking(False)

    my_id = random.getrandbits(32) | 1
    print(f'fake peer {my_id:08x} broadcasting to {target}:{PORT}')
    seq, start, heard, last_report = 0, time.time(), {}, 0.0
    followed = None  # (head position, yaw) of the first headset heard
    followed_id = None
    while time.time() - start < args.seconds:
        t = time.time() - start
        if args.follow and followed:
            # Hover 1 m in front of the headset, facing it, bobbing a little.
            (fx, fy, fz), fyaw = followed
            angle = fyaw + math.pi  # face back towards the headset
            hx = fx - math.sin(fyaw) * 1.0 + math.sin(t * 0.8) * 0.2
            hy = fy + math.sin(t * 1.7) * 0.05
            hz = fz - math.cos(fyaw) * 1.0
            head = (hx, hy, hz) + yaw_quat(angle)
        else:
            # Head circles 1.5 m in front of spawn, facing the direction of travel.
            angle = t * 0.6
            hx, hy, hz = math.sin(angle) * 0.8, 1.2, -1.5 + math.cos(angle) * 0.8
            head = (hx, hy, hz) + yaw_quat(angle + math.pi / 2)
        wave = math.sin(t * 4) * 0.25
        left = (hx - 0.25 * math.cos(angle), hy - 0.35 + wave, hz + 0.25 * math.sin(angle)) + yaw_quat(angle)
        right = (hx + 0.25 * math.cos(angle), hy - 0.35 - wave, hz - 0.25 * math.sin(angle)) + yaw_quat(angle)
        seq += 1
        sock.sendto(PACKET.pack(MAGIC, my_id, seq, *head, *left, *right), (target, PORT))

        try:
            while True:
                data, (ip, _) = sock.recvfrom(256)
                if len(data) == PACKET.size:
                    magic, pid, _, *pose = PACKET.unpack(data)
                    if magic == MAGIC and pid != my_id:
                        heard[pid] = (ip, pose[:3])
                        if followed is None or followed_id == pid:
                            followed_id = pid
                            qx, qy, qz, qw = pose[3:7]
                            # Yaw of the head's forward (-Z) direction.
                            fwd_x = -2 * (qx * qz + qy * qw)
                            fwd_z = -(1 - 2 * (qx * qx + qy * qy))
                            followed = (tuple(pose[:3]), math.atan2(-fwd_x, -fwd_z))
        except BlockingIOError:
            pass
        if time.time() - last_report > 2:
            last_report = time.time()
            for pid, (ip, head_pos) in heard.items():
                print(f'  hearing {pid:08x} from {ip}, head at '
                      f'({head_pos[0]:.2f}, {head_pos[1]:.2f}, {head_pos[2]:.2f})')
            heard.clear()
        time.sleep(1 / 72)


if __name__ == '__main__':
    main()
