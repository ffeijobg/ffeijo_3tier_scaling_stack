// tests/load/backend-load.js
// Targets FastAPI directly via nginx proxy /api/ path.
// Mix of read-heavy (GET) and write (POST) — realistic CRUD pattern.
// The write/read ratio (20/80) exercises DB connection pool under concurrent load.
 
import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Counter, Trend } from 'k6/metrics';
 
const writeErrors = new Rate('write_error_rate');
const readErrors  = new Rate('read_error_rate');
const dbLatency   = new Trend('db_operation_latency', true);
const writeCount  = new Counter('writes_completed');
 
export const options = {
  stages: [
    { duration: '1m',  target: 10  },
    { duration: '2m',  target: 30  },
    { duration: '3m',  target: 80  },   // Should trigger backend HPA at ~65% CPU
    { duration: '3m',  target: 80  },
    { duration: '2m',  target: 20  },
    { duration: '2m',  target: 0   },
  ],
  thresholds: {
    'http_req_duration{type:read}':  ['p(95)<500'],
    'http_req_duration{type:write}': ['p(95)<1000'],
    'write_error_rate': ['rate<0.01'],
    'read_error_rate':  ['rate<0.01'],
  },
};
 
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
 
function randomName() {
  return `item-${Math.random().toString(36).substring(2, 9)}`;
}
 
export default function () {
  // 80% reads, 20% writes — adjust ratio to stress-test write path
  if (Math.random() < 0.8) {
    group('Read items', () => {
      const res = http.get(`${BASE_URL}/api/items?limit=20`, {
        tags: { type: 'read' },
        timeout: '10s',
      });
 
      const ok = check(res, {
        'status 200':    (r) => r.status === 200,
        'has items':     (r) => r.json('count') >= 0,
        'under 500ms':   (r) => r.timings.duration < 500,
      });
 
      readErrors.add(!ok);
      dbLatency.add(res.timings.duration);
    });
  } else {
    group('Write item', () => {
      const payload = {
        name:  randomName(),
        value: `load-test-${Date.now()}`,
      };
 
      const res = http.post(
        `${BASE_URL}/api/items?name=${payload.name}&value=${payload.value}`,
        null,
        { tags: { type: 'write' }, timeout: '10s' }
      );
 
      const ok = check(res, {
        'status 200':   (r) => r.status === 200,
        'has id':       (r) => r.json('id') > 0,
        'under 1s':     (r) => r.timings.duration < 1000,
      });
 
      writeErrors.add(!ok);
      if (ok) writeCount.add(1);
    });
  }
 
  sleep(Math.random() * 0.3 + 0.1);
}
