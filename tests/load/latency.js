// 13. Latency comparison: p50/p95/p99 through the GSLB for blocking.mode = off | lua | opa.
// Run by tests/acceptance/run-blocking-comparison.sh (which switches the mode), or alone:
//   TOKEN=$(scripts/get-token.sh normaluser) MODE=lua k6 run tests/load/latency.js
// Uses the general /orders route (high limits) with a pool of tokens so per-user limits
// (100/min) are not what we measure.
import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';

const GSLB = __ENV.GSLB_URL || 'http://gslb-gslb-sim.localtest.me';   // run-blocking-comparison.sh passes the right one
const MODE = __ENV.MODE || 'unknown';
const TOKENS = (__ENV.TOKENS || __ENV.TOKEN || '').split(',').filter(Boolean);
const RATE = parseInt(__ENV.RATE || '50', 10);         // requests per second (CRC-friendly)

export const options = {
  insecureSkipTLSVerify: true,
  discardResponseBodies: true,
  scenarios: {
    steady: {
      executor: 'constant-arrival-rate',
      rate: RATE, timeUnit: '1s', duration: __ENV.DURATION || '60s',
      preAllocatedVUs: 20, maxVUs: 50,
    },
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(95)', 'p(99)', 'max'],
  thresholds: { checks: ['rate>0.99'] },
  tags: { mode: MODE },
};

export function setup() {
  if (TOKENS.length > 0) return { tokens: TOKENS };
  // fetch tokens for several system clients so no single caller hits its per-user limit
  const kc = __ENV.KEYCLOAK_URL || 'http://keycloak-idp.localtest.me';
  const secret = __ENV.SYSTEM_CLIENT_SECRET;
  if (!secret) throw new Error('set TOKEN(S) or SYSTEM_CLIENT_SECRET');
  const clients = ['reports-service', 'billing-service'];
  return {
    tokens: clients.map((c) => http.post(`${kc}/realms/corp/protocol/openid-connect/token`,
      { grant_type: 'client_credentials', client_id: c, client_secret: secret },
      { responseType: 'text' }).json('access_token')),
  };
}

export default function (data) {
  const token = data.tokens[exec.scenario.iterationInTest % data.tokens.length];
  const res = http.get(`${GSLB}/orders/${exec.scenario.iterationInTest % 1000}`,
    { headers: { Authorization: `Bearer ${token}` }, tags: { name: 'orders' } });
  check(res, { 'status 200': (r) => r.status === 200 });
}
