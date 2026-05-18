// k6-functional.js — functional tests against the deployed Kong gateway.
//
// Scenarios:
//   1. unauthenticated — GET /headers without apikey  -> expect 401 (key-auth)
//   2. authenticated   — GET /headers with apikey     -> expect 200
//   3. rate_limited    — burst GET /status/200 x 12   -> expect >= 5 are 429
//
// Run:
//   k6 run tests/k6-functional.js -e GATEWAY_URL=http://localhost:8080

import http from 'k6/http';
import { check, fail } from 'k6';
import { Counter } from 'k6/metrics';

const GATEWAY_URL = __ENV.GATEWAY_URL || 'http://localhost:8080';
const API_KEY = __ENV.API_KEY || 'demo-key-12345';

const rate_limit_hits = new Counter('rate_limit_hits');

export const options = {
  scenarios: {
    unauthenticated: {
      executor: 'per-vu-iterations',
      vus: 1,
      iterations: 1,
      exec: 'unauthenticated',
    },
    authenticated: {
      executor: 'per-vu-iterations',
      vus: 1,
      iterations: 1,
      exec: 'authenticated',
      startTime: '2s',
    },
    rate_limited: {
      executor: 'per-vu-iterations',
      vus: 1,
      iterations: 1,
      exec: 'rate_limited',
      startTime: '4s',
    },
  },
  thresholds: {
    'checks{scenario:unauthenticated}': ['rate==1.0'],
    'checks{scenario:authenticated}':   ['rate==1.0'],
    'rate_limit_hits':                  ['count>=5'],
  },
};

export function unauthenticated() {
  const res = http.get(`${GATEWAY_URL}/headers`, { tags: { scenario: 'unauthenticated' } });
  check(res, {
    'no api key returns 401': (r) => r.status === 401,
  }, { scenario: 'unauthenticated' });
}

export function authenticated() {
  const res = http.get(`${GATEWAY_URL}/headers`, {
    headers: { apikey: API_KEY },
    tags: { scenario: 'authenticated' },
  });
  check(res, {
    'valid api key returns 200': (r) => r.status === 200,
  }, { scenario: 'authenticated' });
}

export function rate_limited() {
  // 12 sequential requests — rate-limit is 5/min, so requests 6..12 should be 429.
  for (let i = 0; i < 12; i++) {
    const res = http.get(`${GATEWAY_URL}/status/200`, { tags: { scenario: 'rate_limited' } });
    if (res.status === 429) {
      rate_limit_hits.add(1);
    }
  }
}
