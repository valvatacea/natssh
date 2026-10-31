import socket
import threading

WS_PORT = 20865     # GANTI dengan Port NAT kosong untuk Cloudflare
SSH_PORT = 20861    # GANTI dengan Port SSH lokal Anda

def forward(src, dst):
    try:
        while True:
            data = src.recv(4096)
            if not data: break
            dst.send(data)
    except: pass
    finally:
        src.close()
        dst.close()

def handle_client(client_socket):
    try:
        request = client_socket.recv(4096).decode('utf-8', errors='ignore')
        if 'HTTP' in request:
            response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
            client_socket.send(response.encode())
        
        ssh_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        ssh_socket.connect(('127.0.0.1', SSH_PORT))
        
        threading.Thread(target=forward, args=(client_socket, ssh_socket)).start()
        threading.Thread(target=forward, args=(ssh_socket, client_socket)).start()
    except:
        client_socket.close()

if __name__ == '__main__':
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('0.0.0.0', WS_PORT))
    server.listen(100)
    print(f"[*] WebSocket Proxy: Port {WS_PORT} -> SSH Port {SSH_PORT}")
    
    while True:
        client, addr = server.accept()
        threading.Thread(target=handle_client, args=(client,)).start()
