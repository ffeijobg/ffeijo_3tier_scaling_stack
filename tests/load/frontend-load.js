// tests/load/frontend-load.js
// k6 script for nginx load testing.
// Run: k6 run --env BASE_URL=http://localhost:8080 tests/load/frontend-load.js
 
import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend } from 'k6/metrics';
 
// Custom metrics
const errorRate   = new Rate('error_rate');
const nginxLatency = new Trend('nginx_response_time', true);
 
export const options = {
  // Staged ramp: ramp up → sustain → spike → ramp down
  // This pattern is realistic for web traffic and exercises both HPA
  // scale-up (ramp) and scale-down stabilization (ramp down).
  stages: [
    { duration: '1m',  target: 20  },   // Warm up, let HPA settle
    { duration: '3m',  target: 50  },   // Moderate load
    { duration: '2m',  target: 200 },   // Traffic spike — should trigger scale-up
    { duration: '3m',  target: 200 },   // Sustain spike — HPA should stabilize
    { duration: '2m',  target: 50  },   // Decrease load
    { duration: '3m',  target: 50  },   // Hold reduced — HPA stabilization window
    { duration: '2m',  target: 0   },   // Ramp down
  ],
  thresholds: {
    // Hard failure criteria: if any of these breach, k6 exits non-zero (CI fails)
    'http_req_duration{scenario:default}': ['p(95)<200', 'p(99)<500'],
    'http_req_failed': ['rate<0.005'],   // < 0.5% error rate
    'error_rate': ['rate<0.01'],
  },
};
 
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
 
export default function () {
  group('Static content', () => {
    const res = http.get(`${BASE_URL}/`, {
      headers: { 'Accept': 'text/html' },
      timeout: '5s',
    });
 
    const ok = check(res, {
      'status 200':        (r) => r.status === 200,
      'response < 200ms':  (r) => r.timings.duration < 200,
      'has content':       (r) => r.body.length > 0,
    });
 
    errorRate.add(!ok);
    nginxLatency.add(res.timings.duration);
  });
 
  group('Health endpoint', () => {
    const res = http.get(`${BASE_URL}/health`);
    check(res, {
      'health ok':  (r) => r.status === 200,
      'body ok':    (r) => r.json('status') === 'ok',
    });
  });
 
  sleep(Math.random() * 0.5 + 0.1);   // 100-600ms think time (realistic user behavior)
}
 
export function handleSummary(data) {
  return {
    'tests/load/results/frontend-summary.json': JSON.stringify(data, null, 2),
    stdout: textSummary(data, { indent: ' ', enableColors: true }),
  };
}
 
// Import k6 built-in text summary (available in k6 >= 0.38)
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.0.2/index.js';
