#!/usr/bin/env python3
"""Small DNS/TCP/SOCKS harness for the real sing-box fallback test."""

import argparse
import ipaddress
import json
import os
import signal
import socket
import struct
import threading
import time


def log_event(path, event, **fields):
    payload = {"event": event, "time_ns": time.monotonic_ns(), **fields}
    line = (json.dumps(payload, separators=(",", ":")) + "\n").encode()
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, line)
    finally:
        os.close(fd)


def parse_question(packet):
    offset = 12
    labels = []
    while True:
        length = packet[offset]
        offset += 1
        if length == 0:
            break
        labels.append(packet[offset : offset + length].decode("ascii"))
        offset += length
    qtype, qclass = struct.unpack("!HH", packet[offset : offset + 4])
    return ".".join(labels).lower(), qtype, qclass, offset + 4


def dns_response(packet, name, qtype, qclass, question_end, ipv4, ipv6):
    if name != "fallback.test" or qclass != 1 or qtype not in (1, 28):
        flags = 0x8183
        return packet[:2] + struct.pack("!HHHHH", flags, 1, 0, 0, 0) + packet[12:question_end]
    address = ipaddress.ip_address(ipv4 if qtype == 1 else ipv6).packed
    header = packet[:2] + struct.pack("!HHHHH", 0x8180, 1, 1, 0, 0)
    answer = b"\xc0\x0c" + struct.pack("!HHIH", qtype, 1, 30, len(address)) + address
    return header + packet[12:question_end] + answer


def serve(args):
    stop = threading.Event()
    dns_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    dns_sock.bind(("127.0.0.1", args.dns_port))
    tcp_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    tcp_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    tcp_sock.bind((args.ipv4, args.tcp_port))
    tcp_sock.listen(4)

    def dns_loop():
        while not stop.is_set():
            try:
                packet, peer = dns_sock.recvfrom(4096)
                name, qtype, qclass, question_end = parse_question(packet)
                response = dns_response(
                    packet, name, qtype, qclass, question_end, args.ipv4, args.ipv6
                )
                dns_sock.sendto(response, peer)
                if name == "fallback.test" and qtype in (1, 28):
                    log_event(args.events, "dns_response", qtype="A" if qtype == 1 else "AAAA")
            except (OSError, IndexError, UnicodeDecodeError, struct.error):
                if not stop.is_set():
                    raise

    def tcp_loop():
        while not stop.is_set():
            try:
                conn, peer = tcp_sock.accept()
            except OSError:
                if stop.is_set():
                    return
                raise
            with conn:
                log_event(args.events, "ipv4_accept", peer=peer[0])
                conn.settimeout(2)
                try:
                    conn.recv(4096)
                except socket.timeout:
                    pass
                conn.sendall(
                    b"HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\nfallback-ok"
                )

    threading.Thread(target=dns_loop, daemon=True).start()
    threading.Thread(target=tcp_loop, daemon=True).start()

    def shutdown(_signum, _frame):
        stop.set()
        dns_sock.close()
        tcp_sock.close()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    with open(args.ready, "w", encoding="ascii") as ready:
        ready.write("ready\n")
    while not stop.wait(0.1):
        pass


def recv_exact(sock, length):
    chunks = []
    remaining = length
    while remaining:
        chunk = sock.recv(remaining)
        if not chunk:
            raise RuntimeError("unexpected EOF from SOCKS5 server")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def connect(args):
    deadline = time.monotonic() + 10
    while True:
        try:
            sock = socket.create_connection(("127.0.0.1", args.socks_port), timeout=2)
            break
        except OSError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.05)

    with sock:
        sock.settimeout(10)
        sock.sendall(b"\x05\x01\x00")
        if recv_exact(sock, 2) != b"\x05\x00":
            raise RuntimeError("SOCKS5 authentication negotiation failed")
        domain = b"fallback.test"
        request = b"\x05\x01\x00\x03" + bytes([len(domain)]) + domain + struct.pack("!H", args.tcp_port)
        log_event(args.events, "socks_connect_request")
        sock.sendall(request)
        reply = recv_exact(sock, 4)
        if reply[1] != 0:
            raise RuntimeError(f"SOCKS5 connect failed with status {reply[1]}")
        if reply[3] == 1:
            recv_exact(sock, 4)
        elif reply[3] == 3:
            recv_exact(sock, recv_exact(sock, 1)[0])
        elif reply[3] == 4:
            recv_exact(sock, 16)
        else:
            raise RuntimeError("invalid SOCKS5 address type")
        recv_exact(sock, 2)
        sock.sendall(b"GET / HTTP/1.1\r\nHost: fallback.test\r\nConnection: close\r\n\r\n")
        response = bytearray()
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            response.extend(chunk)
    if b"fallback-ok" not in response:
        raise RuntimeError("IPv4 test server response was not received")
    print("fallback-ok")


def assert_timing(args):
    with open(args.events, encoding="utf-8") as stream:
        events = [json.loads(line) for line in stream if line.strip()]
    requests = [event["time_ns"] for event in events if event["event"] == "socks_connect_request"]
    accepts = [event["time_ns"] for event in events if event["event"] == "ipv4_accept"]
    if not requests or not accepts:
        raise RuntimeError("missing SOCKS request or IPv4 accept event")
    first_accept = accepts[0]
    dns = {
        qtype: max(
            event["time_ns"]
            for event in events
            if event["event"] == "dns_response"
            and event["qtype"] == qtype
            and event["time_ns"] <= first_accept
        )
        for qtype in ("A", "AAAA")
        if any(
            event["event"] == "dns_response"
            and event["qtype"] == qtype
            and event["time_ns"] <= first_accept
            for event in events
        )
    }
    if set(dns) != {"A", "AAAA"}:
        raise RuntimeError(f"expected A and AAAA DNS responses, got {sorted(dns)}")
    dns_to_ipv4_ms = (first_accept - max(dns.values())) / 1_000_000
    request_to_ipv4_ms = (first_accept - requests[0]) / 1_000_000
    if not 220 <= dns_to_ipv4_ms <= 900:
        raise RuntimeError(
            f"IPv4 started outside the expected ~300ms window: {dns_to_ipv4_ms:.1f}ms after DNS"
        )
    print(
        f"IPv4 accepted {dns_to_ipv4_ms:.1f}ms after A+AAAA resolution "
        f"({request_to_ipv4_ms:.1f}ms after SOCKS CONNECT)"
    )


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    serve_parser = subparsers.add_parser("serve")
    serve_parser.add_argument("--events", required=True)
    serve_parser.add_argument("--ready", required=True)
    serve_parser.add_argument("--ipv4", required=True)
    serve_parser.add_argument("--ipv6", required=True)
    serve_parser.add_argument("--dns-port", type=int, required=True)
    serve_parser.add_argument("--tcp-port", type=int, required=True)
    serve_parser.set_defaults(func=serve)

    connect_parser = subparsers.add_parser("connect")
    connect_parser.add_argument("--events", required=True)
    connect_parser.add_argument("--socks-port", type=int, required=True)
    connect_parser.add_argument("--tcp-port", type=int, required=True)
    connect_parser.set_defaults(func=connect)

    assert_parser = subparsers.add_parser("assert")
    assert_parser.add_argument("--events", required=True)
    assert_parser.set_defaults(func=assert_timing)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
