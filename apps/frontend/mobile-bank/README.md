# Mobile Bank Frontend (Flutter)

## Prerequisites

- Flutter SDK installed (`flutter --version`)
- Chrome available for web run
- Backend running on:
  - `http://localhost:8080` (v1)

## First-time setup

If this folder does not contain platform files yet, generate them once:

```bash
cd apps/frontend/mobile-bank
flutter create .
```

Install dependencies:

```bash
flutter pub get
```

## Run locally (web)

```bash
cd apps/frontend/mobile-bank
flutter run -d chrome
```

If the browser does not open automatically, use the URL shown by `flutter run`.

## How to use

1. Keep both backend instances running.
2. In the app:
   - Backend endpoint: `http://localhost:8080/api/v1/accounts/summary`
3. The app auto-loads balances at startup.
4. Click:
   - `Refresh` to update balances and totals.
   - `Transfer` to send an external transfer with random amount (`500`, `1000`, `5000`).
5. Transfers reduce total balance and update the `Last 5 transfers` history.
6. Open settings through the gear icon in the top-right corner.
7. Check `Live operations feed (WebSocket)` for real-time events from `/ws/live`.

## Backend URL persistence and deployment defaults

- Backend endpoint URL is saved in browser `localStorage`.
- After page refresh, the app restores the backend URL.

Build-time defaults (for container/deployment) are supported via `dart-define`:

- `PRIMARY_BACKEND_URL`
- `MCP_GATEWAY_URL`

The `MCP Integration` tab stores its editable gateway endpoint in browser
`localStorage` and calls the MCP Gateway `/mcp` endpoint directly.
