#!/usr/bin/env python3
"""Scan 192.168.2.0/24 for web listeners on ports 80 and 443."""

import socket
import ssl
import concurrent.futures
from collections import defaultdict

SUBNET = "192.168.2"
PORTS = [80, 443]
TIMEOUT = 1.5  # seconds


def grab_banner(ip: str, port: int) -> dict | None:
    """Try to connect and grab the HTTP Server header."""
    try:
        raw = socket.create_connection((ip, port), timeout=TIMEOUT)
        if port == 443:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            sock = ctx.wrap_socket(raw, server_hostname=ip)
        else:
            sock = raw

        sock.sendall(b"HEAD / HTTP/1.0\r\nHost: " + ip.encode() + b"\r\n\r\n")
        data = sock.recv(4096).decode("utf-8", errors="replace")
        sock.close()

        # Pull status line + Server header
        status = data.split("\r\n", 1)[0] if data else ""
        server = ""
        for line in data.split("\r\n"):
            if line.lower().startswith("server:"):
                server = line.split(":", 1)[1].strip()
                break

        return {"ip": ip, "port": port, "status": status, "server": server}
    except (socket.timeout, ConnectionRefusedError, OSError, ssl.SSLError):
        return None


def main():
    targets = [(f"{SUBNET}.{i}", port) for i in range(1, 255) for port in PORTS]
    results = []

    print(f"Scanning {SUBNET}.1-254 on ports {PORTS} …\n")

    with concurrent.futures.ThreadPoolExecutor(max_workers=80) as pool:
        futures = {pool.submit(grab_banner, ip, port): (ip, port) for ip, port in targets}
        for f in concurrent.futures.as_completed(futures):
            r = f.result()
            if r:
                results.append(r)
                scheme = "https" if r["port"] == 443 else "http"
                tag = f'  Server: {r["server"]}' if r["server"] else ""
                print(f'  {scheme}://{r["ip"]}  {r["status"]}{tag}')

    if not results:
        print("No web listeners found.")
    else:
        print(f"\n✓ Found {len(results)} open web port(s) across {len({r['ip'] for r in results})} host(s).")


if __name__ == "__main__":
    main()