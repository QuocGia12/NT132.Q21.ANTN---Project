# Load Test Lab

This repo includes a small `k6` lab for safe load testing of the deployed web app.

File:

- `loadtest/k6-webapp.js`
- `loadtest/run-with-observe.sh`

The script is designed around the current architecture:

- public entrypoint: `blood-bank.com`
- frontend ingress serves the SPA
- frontend Nginx proxies `/api/*` to the internal backend service

## Safety Notes

- Run this only against a staging or isolated lab environment you own.
- Do not point `MODE=login` at production because each login updates `lastLogin` and facility history in MongoDB.
- Start small and increase gradually.

## Supported Modes

### `MODE=smoke`

Checks:

- `GET /`
- `GET /login`

Use this first to verify the ingress, frontend service, and frontend pod are healthy.

### `MODE=login`

Checks:

- `POST /api/auth/login`

Use this to test the real login API path through:

`load balancer -> ingress -> frontend -> frontend nginx proxy -> backend service -> backend pod`

### `MODE=authenticated`

Checks:

- `GET /login`
- `GET /api/auth/profile`

This mode logs in once during `setup()` and reuses the bearer token for the test, which avoids unnecessary repeated writes compared with `MODE=login`.

## Prerequisites

You need one of the following:

1. `k6` installed locally
2. Docker available to run the `grafana/k6` image

Your local machine must resolve the app domain. Because your load balancer VM is `192.168.245.105`, a hosts entry like this is sufficient:

```text
192.168.245.105 blood-bank.com
```

## Credentials

If you seeded the default admin from `backend/seedAdmin.js`, you can use:

- email: `suraj@admin.com`
- password: `bbms@admin`

## Run Examples

### 1. Smoke test

```bash
k6 run \
  -e BASE_URL=http://blood-bank.com \
  -e MODE=smoke \
  -e VUS=1 \
  -e DURATION=30s \
  loadtest/k6-webapp.js
```

### 2. Light login test

```bash
k6 run \
  -e BASE_URL=http://blood-bank.com \
  -e MODE=login \
  -e LOGIN_EMAIL=nguyengia595@gmai.com \
  -e LOGIN_PASSWORD=12345678 \
  -e VUS=3 \
  -e DURATION=45s \
  -e THINK_TIME=1 \
  loadtest/k6-webapp.js
```

### 3. Authenticated API test without repeated logins

```bash
k6 run \
  -e BASE_URL=http://blood-bank.com \
  -e MODE=authenticated \
  -e LOGIN_EMAIL=suraj@admin.com \
  -e LOGIN_PASSWORD=bbms@admin \
  -e VUS=10 \
  -e DURATION=2m \
  -e THINK_TIME=1 \
  loadtest/k6-webapp.js
```

## Docker Alternative

If you prefer Docker:

```bash
docker run --rm -i --add-host blood-bank.com:192.168.245.105 \
  -v "$PWD:/work" \
  -w /work \
  grafana/k6 run \
  -e BASE_URL=http://blood-bank.com \
  -e MODE=smoke \
  loadtest/k6-webapp.js
```

For login mode:

```bash
docker run --rm -i --add-host blood-bank.com:192.168.245.105 \
  -v "$PWD:/work" \
  -w /work \
  grafana/k6 run \
  -e BASE_URL=http://blood-bank.com \
  -e MODE=login \
  -e LOGIN_EMAIL=suraj@admin.com \
  -e LOGIN_PASSWORD=bbms@admin \
  -e VUS=3 \
  -e DURATION=45s \
  loadtest/k6-webapp.js
```

## Run With Kubernetes Observation

`loadtest/run-with-observe.sh` starts background watchers and saves all outputs under `loadtest/output/<mode>-<timestamp>/`.

Collected files include:

- `k6.log`
- `pods-watch.log`
- `top-pods.log`
- `top-nodes.log`
- `backend-logs.log`
- `frontend-logs.log`
- `cluster-snapshot.log`
- `ingress-describe.log`
- `events-initial.log`
- `events-final.log`

### Local `k6`

```bash
chmod +x loadtest/run-with-observe.sh

MODE=authenticated \
BASE_URL=http://blood-bank.com \
LOGIN_EMAIL=suraj@admin.com \
LOGIN_PASSWORD=bbms@admin \
VUS=10 \
DURATION=2m \
THINK_TIME=1 \
./loadtest/run-with-observe.sh
```

### Docker `k6`

```bash
chmod +x loadtest/run-with-observe.sh

RUNNER=docker \
MODE=smoke \
BASE_URL=http://blood-bank.com \
LB_HOST=blood-bank.com \
LB_IP=192.168.245.105 \
./loadtest/run-with-observe.sh
```

### With ingress controller logs

If you know the ingress controller deployment name, add it:

```bash
RUNNER=docker \
MODE=login \
BASE_URL=http://blood-bank.com \
LOGIN_EMAIL=suraj@admin.com \
LOGIN_PASSWORD=bbms@admin \
VUS=3 \
DURATION=45s \
INGRESS_NAMESPACE=ingress-nginx \
INGRESS_DEPLOYMENT=ingress-nginx-controller \
./loadtest/run-with-observe.sh
```

### Useful environment variables

- `NAMESPACE`: defaults to `blood-bank`
- `RUNNER`: `local` or `docker`
- `MODE`: `smoke`, `login`, `authenticated`
- `BASE_URL`: defaults to `http://blood-bank.com`
- `VUS`, `DURATION`, `THINK_TIME`
- `REQUEST_TIMEOUT`: optional, for example `15s` or `30s`
- `LOGIN_EMAIL`, `LOGIN_PASSWORD`
- `AUTH_TOKEN`: optional for authenticated mode
- `TOP_INTERVAL`: seconds between `kubectl top` snapshots, default `5`
- `FRONTEND_DEPLOYMENT`: defaults to `blood-bank-frontend-deployment`
- `BACKEND_DEPLOYMENT`: defaults to `blood-bank-backend-deployment`
- `INGRESS_NAMESPACE`, `INGRESS_DEPLOYMENT`: optional ingress controller logs

## Recommended Order

Run tests in this order:

1. `MODE=smoke`
2. `MODE=authenticated`
3. `MODE=login`

This avoids jumping straight into the write-heavy login path before you confirm ingress and routing work.

## What to Watch During the Test

Watch these components with `kubectl` while the test is running:

- ingress controller pod CPU and latency
- frontend pod CPU and restarts
- backend pod CPU, memory, and restarts
- backend logs for `401`, `403`, `500`, MongoDB errors
- response times and error rate in `k6`

Example:

```bash
kubectl get pods -n blood-bank -w
kubectl top pods -n blood-bank
kubectl logs -n blood-bank deploy/blood-bank-backend-deployment -f
```

## Suggested Safe Starting Limits

- smoke: `1 VU`, `30s`
- authenticated: `5-10 VU`, `1-2m`
- login: `2-5 VU`, `30-45s`

Only increase after you confirm:

- no 5xx spikes
- no pod restarts
- MongoDB stays reachable
- latency stays acceptable
