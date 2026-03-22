import http from "k6/http";
import { check, fail, group, sleep } from "k6";
import { Rate } from "k6/metrics";

const BASE_URL = (__ENV.BASE_URL || "http://blood-bank.com").replace(/\/+$/, "");
const MODE = (__ENV.MODE || "smoke").toLowerCase();
const LOGIN_EMAIL = __ENV.LOGIN_EMAIL || "";
const LOGIN_PASSWORD = __ENV.LOGIN_PASSWORD || "";
const AUTH_TOKEN = __ENV.AUTH_TOKEN || "";
const THINK_TIME = Number(__ENV.THINK_TIME || "1");
const VUS = Number(__ENV.VUS || defaultVus(MODE));
const DURATION = __ENV.DURATION || defaultDuration(MODE);
const REQUEST_TIMEOUT = __ENV.REQUEST_TIMEOUT || "";

const loginSuccess = new Rate("login_success");
const profileSuccess = new Rate("profile_success");

function defaultVus(mode) {
  switch (mode) {
    case "login":
      return 5;
    case "authenticated":
      return 10;
    case "smoke":
    default:
      return 1;
  }
}

function defaultDuration(mode) {
  switch (mode) {
    case "login":
      return "1m";
    case "authenticated":
      return "2m";
    case "smoke":
    default:
      return "30s";
  }
}

function jsonHeaders(token) {
  const headers = {
    "Content-Type": "application/json",
  };

  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  return headers;
}

function buildUrl(path) {
  return `${BASE_URL}${path}`;
}

function requestParams(params = {}) {
  if (!REQUEST_TIMEOUT) {
    return params;
  }

  return {
    ...params,
    timeout: REQUEST_TIMEOUT,
  };
}

function hasBody(response) {
  return Boolean(response && typeof response.body === "string" && response.body.length > 0);
}

function safeJsonValue(response, selector) {
  if (!hasBody(response)) {
    return undefined;
  }

  try {
    return selector ? response.json(selector) : response.json();
  } catch (_) {
    return undefined;
  }
}

function thresholdsForMode(mode) {
  const baseThresholds = {
    http_req_failed: ["rate<0.05"],
    http_req_duration: ["p(95)<1500"],
  };

  if (mode === "login") {
    return {
      ...baseThresholds,
      login_success: ["rate>0.95"],
    };
  }

  if (mode === "authenticated") {
    return {
      ...baseThresholds,
      login_success: ["rate>0.95"],
      profile_success: ["rate>0.95"],
    };
  }

  return baseThresholds;
}

export const options = {
  vus: VUS,
  duration: DURATION,
  thresholds: thresholdsForMode(MODE),
};

export function setup() {
  if (MODE !== "authenticated") {
    return { token: AUTH_TOKEN || "" };
  }

  if (AUTH_TOKEN) {
    return { token: AUTH_TOKEN };
  }

  if (!LOGIN_EMAIL || !LOGIN_PASSWORD) {
    fail("MODE=authenticated requires AUTH_TOKEN or LOGIN_EMAIL and LOGIN_PASSWORD");
  }

  const payload = JSON.stringify({
    email: LOGIN_EMAIL,
    password: LOGIN_PASSWORD,
  });

  const response = http.post(buildUrl("/api/auth/login"), payload, {
    ...requestParams({
      headers: jsonHeaders(),
      tags: { endpoint: "auth_login_setup" },
    }),
  });

  const ok = check(response, {
    "setup login status is 200": (r) => r.status === 200,
    "setup login returns token": (r) => Boolean(safeJsonValue(r, "token")),
  });

  loginSuccess.add(ok);

  if (!ok) {
    fail(`Setup login failed with status ${response.status}: ${response.body || "empty response body"}`);
  }

  return { token: safeJsonValue(response, "token") };
}

export default function (data) {
  switch (MODE) {
    case "login":
      runLoginFlow();
      break;
    case "authenticated":
      runAuthenticatedFlow(data?.token || "");
      break;
    case "smoke":
    default:
      runSmokeFlow();
      break;
  }

  sleep(THINK_TIME);
}

function runSmokeFlow() {
  group("frontend smoke flow", () => {
    const landing = http.get(buildUrl("/"), {
      ...requestParams({
        tags: { endpoint: "landing_page" },
      }),
    });

    check(landing, {
      "landing returns 200": (r) => r.status === 200,
      "landing contains app shell": (r) =>
        r.body.includes("<!doctype html>") || r.body.includes("<!DOCTYPE html>"),
    });

    const loginPage = http.get(buildUrl("/login"), {
      ...requestParams({
        tags: { endpoint: "login_page" },
      }),
    });

    check(loginPage, {
      "login page returns 200": (r) => r.status === 200,
      "login page contains login text": (r) =>
        r.body.includes("Login") || r.body.includes("Blood Bank"),
    });
  });
}

function runLoginFlow() {
  if (!LOGIN_EMAIL || !LOGIN_PASSWORD) {
    fail("MODE=login requires LOGIN_EMAIL and LOGIN_PASSWORD");
  }

  group("login api flow", () => {
    const response = http.post(
      buildUrl("/api/auth/login"),
      JSON.stringify({
        email: LOGIN_EMAIL,
        password: LOGIN_PASSWORD,
      }),
      {
        ...requestParams({
          headers: jsonHeaders(),
          tags: { endpoint: "auth_login" },
        }),
      }
    );

    const ok = check(response, {
      "login returns 200": (r) => r.status === 200,
      "login returns token": (r) => Boolean(safeJsonValue(r, "token")),
      "login returns redirect": (r) => Boolean(safeJsonValue(r, "redirect")),
    });

    loginSuccess.add(ok);
  });
}

function runAuthenticatedFlow(token) {
  if (!token) {
    fail("MODE=authenticated requires a bearer token from setup or AUTH_TOKEN");
  }

  group("frontend plus authenticated api flow", () => {
    const loginPage = http.get(buildUrl("/login"), {
      ...requestParams({
        tags: { endpoint: "login_page" },
      }),
    });

    check(loginPage, {
      "login page returns 200": (r) => r.status === 200,
    });

    const profile = http.get(buildUrl("/api/auth/profile"), {
      ...requestParams({
        headers: jsonHeaders(token),
        tags: { endpoint: "auth_profile" },
      }),
    });

    const ok = check(profile, {
      "profile returns 200": (r) => r.status === 200,
      "profile contains user object": (r) => Boolean(safeJsonValue(r, "user")),
    });

    profileSuccess.add(ok);
  });
}
