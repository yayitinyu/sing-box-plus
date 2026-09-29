"""Exercise generated Shadowsocks -> SOCKS routes without external services."""

import copy
import json
import socket
import socketserver
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path


def receive(sock, length):
    result = bytearray()
    while len(result) < length:
        chunk = sock.recv(length - len(result))
        if not chunk:
            raise EOFError("Unexpected end of proxy handshake")
        result.extend(chunk)
    return bytes(result)


class SocksUpstream(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        version, count = receive(self.request, 2)
        methods = receive(self.request, count)
        if version != 5 or 2 not in methods:
            raise AssertionError("Expected SOCKS5 authentication")
        self.request.sendall(b"\x05\x02")
        version, length = receive(self.request, 2)
        username = receive(self.request, length)
        password = receive(self.request, receive(self.request, 1)[0])
        if version != 1 or username != b"test" or password != b"secret":
            raise AssertionError("Imported upstream authentication was not used")
        self.request.sendall(b"\x01\x00")
        version, command, reserved, address_type = receive(self.request, 4)
        if (version, command, reserved) != (5, 1, 0):
            raise AssertionError("Expected SOCKS5 CONNECT")
        if address_type == 1:
            address = socket.inet_ntop(socket.AF_INET, receive(self.request, 4))
        elif address_type == 3:
            address = receive(self.request, receive(self.request, 1)[0]).decode()
        elif address_type == 4:
            address = socket.inet_ntop(socket.AF_INET6, receive(self.request, 16))
        else:
            raise AssertionError("Unexpected SOCKS address type")
        port = struct.unpack("!H", receive(self.request, 2))[0]
        self.server.destinations.append((address_type, address, port))
        self.request.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x50")
        request = bytearray()
        while b"\r\n\r\n" not in request:
            request.extend(receive(self.request, 1))
            if len(request) > 8192:
                raise AssertionError("Oversized HTTP probe")
        body = b"socks-node-ok"
        self.request.sendall(
            b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: "
            + str(len(body)).encode()
            + b"\r\n\r\n"
            + body
        )


class DnsResolver(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        end = 12
        labels = []
        while data[end]:
            size = data[end]
            labels.append(data[end + 1 : end + size + 1].decode())
            end += size + 1
        name = ".".join(labels)
        end += 1
        question_type = struct.unpack("!H", data[end : end + 2])[0]
        end += 4
        self.server.queries.append(name)
        answers = 1 if question_type == 1 else 0
        response = data[:2] + struct.pack("!HHHHH", 0x8180, 1, answers, 0, 0) + data[12:end]
        if answers:
            response += b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 60, 4) + socket.inet_aton("127.0.0.1")
        sock.sendto(response, self.client_address)


def available_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_ready(process, port):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("sing-box exited before the probe was ready")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.05)
    raise TimeoutError("sing-box did not start listening")


def request_through_socks(port, name):
    with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
        sock.sendall(b"\x05\x01\x00")
        if receive(sock, 2) != b"\x05\x00":
            raise AssertionError("Client SOCKS handshake failed")
        domain = name.encode()
        sock.sendall(b"\x05\x01\x00\x03" + bytes([len(domain)]) + domain + b"\x00\x50")
        if receive(sock, 4) != b"\x05\x00\x00\x01":
            raise AssertionError("Client SOCKS CONNECT failed")
        receive(sock, 6)
        sock.sendall(b"GET / HTTP/1.1\r\nHost: " + domain + b"\r\nConnection: close\r\n\r\n")
        result = bytearray()
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            result.extend(chunk)
        if not bytes(result).endswith(b"socks-node-ok"):
            raise AssertionError("HTTP payload did not traverse the imported SOCKS upstream")


def main():
    binary, config_path, output_directory = sys.argv[1:]
    generated = json.loads(Path(config_path).read_text(encoding="utf-8"))
    nodes = [item for item in generated["inbounds"] if item["tag"].startswith("sbp-socks-") and item["type"] == "shadowsocks" and item["method"] == "aes-256-gcm"]
    if len(nodes) != 2:
        raise AssertionError("Expected generated local and remote DNS Shadowsocks nodes")
    output = Path(output_directory)
    upstream = socketserver.ThreadingTCPServer(("127.0.0.1", 0), SocksUpstream)
    upstream.daemon_threads = True
    upstream.destinations = []
    resolver = socketserver.ThreadingUDPServer(("127.0.0.1", 0), DnsResolver)
    resolver.daemon_threads = True
    resolver.queries = []
    processes = []
    logs = []
    try:
        for service in (upstream, resolver):
            threading.Thread(target=service.serve_forever, daemon=True).start()
        for index, node in enumerate(nodes):
            node = copy.deepcopy(node)
            node["listen"] = "127.0.0.1"
            node["listen_port"] = available_port()
            routes = [rule for rule in generated["route"]["rules"] if rule.get("inbound") == [node["tag"]]]
            local_dns = any(rule["action"] == "resolve" for rule in routes)
            target_tag = next(rule["outbound"] for rule in routes if rule["action"] == "route")
            outbound = copy.deepcopy(next(item for item in generated["outbounds"] if item["tag"] == target_tag))
            outbound.update(server="127.0.0.1", server_port=upstream.server_address[1])
            server_config = {
                "log": {"level": "error"},
                "dns": {"servers": [{"type": "udp", "tag": "dns-doh-primary", "server": "127.0.0.1", "server_port": resolver.server_address[1]}], "final": "dns-doh-primary", "strategy": "prefer_ipv4"},
                "inbounds": [node], "outbounds": [outbound],
                "route": {"rules": routes},
            }
            client_port = available_port()
            client_config = {
                "log": {"level": "error"},
                "inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": client_port}],
                "outbounds": [{"type": "shadowsocks", "tag": "test-node", "server": "127.0.0.1", "server_port": node["listen_port"], "method": node["method"], "password": node["password"]}],
                "route": {"final": "test-node"},
            }
            for label, config, port in (("server", server_config, node["listen_port"]), ("client", client_config, client_port)):
                path = output / f"probe-{index}-{label}.json"
                path.write_text(json.dumps(config), encoding="utf-8")
                log = (output / f"probe-{index}-{label}.log").open("w", encoding="utf-8")
                logs.append(log)
                process = subprocess.Popen([binary, "run", "-c", str(path)], stdout=log, stderr=subprocess.STDOUT)
                processes.append(process)
                wait_ready(process, port)
            domain = "local.example.test" if local_dns else "remote.example.test"
            request_through_socks(client_port, domain)
            expected = (1, "127.0.0.1", 80) if local_dns else (3, domain, 80)
            if upstream.destinations[-1] != expected:
                raise AssertionError(f"Wrong SOCKS destination: {upstream.destinations[-1]} != {expected}")
        if "local.example.test" not in resolver.queries or "remote.example.test" in resolver.queries:
            raise AssertionError("SOCKS5H leaked target DNS to the local resolver")
        print("PASS: real Shadowsocks -> authenticated SOCKS5 traffic and local/remote target DNS")
    finally:
        for process in reversed(processes):
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        for log in logs:
            log.close()
        for service in (upstream, resolver):
            service.shutdown()
            service.server_close()


if __name__ == "__main__":
    main()
