# WhatsReply Server UI

This is a small local history server for the Flutter app. It uses only Python's standard library and SQLite.

## Start on Windows

Double-click `start_server.bat`, or run:

```powershell
cd E:\VASANTS\WHATSAPPREPLY\whatsreply\server_ui
python server.py
```

Open `http://127.0.0.1:8765` on the PC. From a phone on the same Tailscale network, open `http://<PC_TAILSCALE_IP>:8765`.

The Flutter app sends each successfully delivered WhatsApp auto-reply to `http://<PC_TAILSCALE_IP>:8765/api/logs`. The database is created automatically as `whatsapp_history.sqlite3`.

The Android app checks `GET /api/health` every 10 seconds and shows Server connected/disconnected on its dashboard. The browser dashboard refreshes the history every 10 seconds.

If Windows Firewall blocks the port, run Command Prompt as Administrator:

```cmd
netsh advfirewall firewall add rule name="WhatsReply Server 8765" dir=in action=allow protocol=TCP localport=8765
```
