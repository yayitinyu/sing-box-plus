"""Exercise generated Shadowsocks -> SOCKS routes without external services."""

import copy
import ipaddress
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


def serve_http(sock, body):
    request = bytearray()
    while b"\r\n\r\n" not in request:
        request.extend(receive(sock, 1))
        if len(request) > 8192:
            raise AssertionError("Oversized HTTP probe")
    sock.sendall(
        b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: "
        + str(len(body)).encode()
        + b"\r\n\r\n"
        + body
    )


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
        if port == self.server.reject_port:
            self.request.sendall(b"\x05\x05\x00\x01\x7f\x00\x00\x01\x00\x00")
            return
        self.request.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x50")
        serve_http(self.request, self.server.response_body)


class DirectHttp(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        serve_http(self.request, b"direct-route-ok")


class Ipv6Http(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        serve_http(self.request, b"system-ipv6-ok")


class Ipv6Server(socketserver.ThreadingTCPServer):
    address_family = socket.AF_INET6
    daemon_threads = True


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
        answer = b""
        if question_type == 1 and name not in ("v6.example.test", "override-v6.example.test"):
            answer = socket.inet_aton("127.0.0.1")
        elif question_type == 28 and name in ("v6.example.test", "override-v6.example.test", "dual.example.test", "refuse.example.test"):
            answer = socket.inet_pton(socket.AF_INET6, "::1")
        answers = int(bool(answer))
        response = data[:2] + struct.pack("!HHHHH", 0x8180, 1, answers, 0, 0) + data[12:end]
        if answers:
            response += b"\xc0\x0c" + struct.pack("!HHIH", question_type, 1, 60, len(answer)) + answer
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


def request_through_socks(port, name, destination_port=80, expected_body=b"socks-node-ok"):
    with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
        sock.sendall(b"\x05\x01\x00")
        if receive(sock, 2) != b"\x05\x00":
            raise AssertionError("Client SOCKS handshake failed")
        try:
            address = ipaddress.ip_address(name)
        except ValueError:
            domain = name.encode()
            target = b"\x03" + bytes([len(domain)]) + domain
        else:
            target = bytes([1 if address.version == 4 else 4]) + address.packed
        sock.sendall(b"\x05\x01\x00" + target + struct.pack("!H", destination_port))
        reply = receive(sock, 4)
        if reply[:3] != b"\x05\x00\x00":
            raise AssertionError(f"Client SOCKS CONNECT failed for {name}: {reply.hex()}")
        if reply[3] == 1:
            receive(sock, 6)
        elif reply[3] == 4:
            receive(sock, 18)
        elif reply[3] == 3:
            receive(sock, receive(sock, 1)[0] + 2)
        else:
            raise AssertionError("Invalid SOCKS reply address type")
        sock.sendall(b"GET / HTTP/1.1\r\nHost: " + name.encode() + b"\r\nConnection: close\r\n\r\n")
        result = bytearray()
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            result.extend(chunk)
        if not bytes(result).endswith(expected_body):
            raise AssertionError(f"Wrong egress for {name}: expected {expected_body!r}")


def main():
    binary, config_path, output_directory = sys.argv[1:]
    generated = json.loads(Path(config_path).read_text(encoding="utf-8"))
    nodes = [item for item in generated["inbounds"] if item["tag"].startswith("sbp-socks-") and item["type"] == "shadowsocks" and item["method"] == "aes-256-gcm"]
    if len(nodes) != 4:
        raise AssertionError("Expected local/remote DNS Shadowsocks nodes with system IPv6 on/off")
    output = Path(output_directory)
    upstream = socketserver.ThreadingTCPServer(("127.0.0.1", 0), SocksUpstream)
    upstream.daemon_threads = True
    upstream.destinations = []
    upstream.response_body = b"socks-node-ok"
    custom_upstream = socketserver.ThreadingTCPServer(("127.0.0.1", 0), SocksUpstream)
    custom_upstream.daemon_threads = True
    custom_upstream.destinations = []
    custom_upstream.response_body = b"custom-route-ok"
    custom_upstream.reject_port = 0
    direct_http = socketserver.ThreadingTCPServer(("127.0.0.1", 0), DirectHttp)
    direct_http.daemon_threads = True
    resolver = socketserver.ThreadingUDPServer(("127.0.0.1", 0), DnsResolver)
    resolver.daemon_threads = True
    resolver.queries = []
    ipv6_http = Ipv6Server(("::1", 0), Ipv6Http)
    upstream.reject_port = ipv6_http.server_address[1]
    processes = []
    logs = []
    try:
        for service in (upstream, custom_upstream, direct_http, resolver, ipv6_http):
            threading.Thread(target=service.serve_forever, daemon=True).start()
        for index, node in enumerate(nodes):
            node = copy.deepcopy(node)
            node["listen"] = "127.0.0.1"
            node["listen_port"] = available_port()
            routes = [rule for rule in generated["route"]["rules"] if rule.get("inbound") in (None, [node["tag"]])]
            node_routes = [rule for rule in routes if rule.get("inbound") == [node["tag"]]]
            local_dns = any(rule["action"] == "resolve" for rule in node_routes)
            system_ipv6 = any(rule.get("ip_cidr") == ["::/0"] for rule in node_routes)
            target_tag = next(rule["outbound"] for rule in node_routes if rule["action"] == "route" and rule["outbound"] != "sbp-socks-ipv6")
            outbound = copy.deepcopy(next(item for item in generated["outbounds"] if item["tag"] == target_tag))
            outbound.update(server="127.0.0.1", server_port=upstream.server_address[1])
            custom_outbound = copy.deepcopy(next(item for item in generated["outbounds"] if item["tag"] == "custom-probe"))
            custom_outbound["server_port"] = custom_upstream.server_address[1]
            direct_outbound = copy.deepcopy(next(item for item in generated["outbounds"] if item["tag"] == "direct"))
            outbounds = [outbound, custom_outbound, direct_outbound]
            if system_ipv6:
                ipv6_outbound = copy.deepcopy(next(item for item in generated["outbounds"] if item["tag"] == "sbp-socks-ipv6"))
                ipv6_outbound["inet6_bind_address"] = "::1"
                outbounds.append(ipv6_outbound)
            server_config = {
                "log": {"level": "error"},
                "dns": {"servers": [{"type": "udp", "tag": "dns-doh-primary", "server": "127.0.0.1", "server_port": resolver.server_address[1]}], "final": "dns-doh-primary", "strategy": "prefer_ipv4"},
                "inbounds": [node], "outbounds": outbounds,
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
            before_direct = (len(upstream.destinations), len(custom_upstream.destinations))
            request_through_socks(client_port, "direct.example.test", direct_http.server_address[1], b"direct-route-ok")
            if before_direct != (len(upstream.destinations), len(custom_upstream.destinations)):
                raise AssertionError("Explicit direct routing must bypass SOCKS exits")
            for destination in ("override.example.test", "override-v6.example.test"):
                before_override = len(upstream.destinations)
                request_through_socks(client_port, destination, expected_body=b"custom-route-ok")
                if len(upstream.destinations) != before_override:
                    raise AssertionError("Explicit custom routing must bypass the node's default SOCKS exit")
                if custom_upstream.destinations[-1] != (3, destination, 80):
                    raise AssertionError("Custom routing must match domains before fallback DNS/IPv6 routing")
            before_block = (len(upstream.destinations), len(custom_upstream.destinations))
            try:
                request_through_socks(client_port, "blocked.example.test")
            except (AssertionError, EOFError, OSError):
                pass
            else:
                raise AssertionError("Global blocking must apply to optional SOCKS nodes")
            if before_block != (len(upstream.destinations), len(custom_upstream.destinations)):
                raise AssertionError("Blocked traffic must never reach a SOCKS upstream")
            domain = "local.example.test" if local_dns else "remote.example.test"
            request_through_socks(client_port, domain)
            expected = (1, "127.0.0.1", 80) if local_dns else (3, domain, 80)
            if upstream.destinations[-1] != expected:
                raise AssertionError(f"Wrong SOCKS destination: {upstream.destinations[-1]} != {expected}")
            if system_ipv6:
                request_through_socks(client_port, "dual.example.test")
                if upstream.destinations[-1] != (1, "127.0.0.1", 80):
                    raise AssertionError("Dual-stack domains must prefer IPv4 through SOCKS")
                request_through_socks(client_port, "127.0.0.1")
                if upstream.destinations[-1] != (1, "127.0.0.1", 80):
                    raise AssertionError("Literal IPv4 must use SOCKS")
                before_ipv6 = len(upstream.destinations)
                for destination in ("v6.example.test", "::1"):
                    request_through_socks(client_port, destination, ipv6_http.server_address[1], b"system-ipv6-ok")
                if len(upstream.destinations) != before_ipv6:
                    raise AssertionError("System IPv6 traffic must bypass the IPv4 SOCKS upstream")
                before_failure = len(upstream.destinations)
                try:
                    request_through_socks(client_port, "refuse.example.test", ipv6_http.server_address[1], b"system-ipv6-ok")
                except (AssertionError, EOFError, OSError):
                    pass
                else:
                    raise AssertionError("Failed SOCKS IPv4 must not switch to the system IPv6 exit")
                failed_attempts = upstream.destinations[before_failure:]
                if not failed_attempts or any(item[0] != 1 for item in failed_attempts):
                    raise AssertionError("Dual-stack SOCKS retries must stay on IPv4")
        if "local.example.test" not in resolver.queries or "remote.example.test" in resolver.queries:
            raise AssertionError("SOCKS5H leaked target DNS to the local resolver")
        print("PASS: real SOCKS5, custom/direct routing and blocking, local/remote DNS, IPv4 preference and system IPv6")
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
        for service in (upstream, custom_upstream, direct_http, resolver, ipv6_http):
            service.shutdown()
            service.server_close()


if __name__ == "__main__":
    main()
