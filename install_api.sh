#!/bin/bash
set -e
if [ ! -d /root/natssh ]; then
    echo "natssh belum terpasang."
    exit 1
fi
/usr/bin/python3 -m pip install --break-system-packages --ignore-installed -r /root/natssh/api/requirements.txt
if [ ! -f /root/natssh/.api_token ]; then
    /usr/bin/python3 -c "import secrets; print(secrets.token_urlsafe(48))" > /root/natssh/.api_token
fi
TOKEN=$(cat /root/natssh/.api_token)
cat > /etc/systemd/system/natssh-api.service <<EOF
[Unit]
Description=NATSSH API
After=network.target natssh-ws.service

[Service]
Environment=NATSSH_API_TOKEN=$TOKEN
ExecStart=/usr/bin/python3 -m uvicorn api.main:app --host 127.0.0.1 --port 8099
WorkingDirectory=/root/natssh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now natssh-api
echo "API installed. Token: $TOKEN"
