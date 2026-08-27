import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Rate, Counter } from 'k6/metrics';

export const options = {
  vus: 400,
  duration: '1m',

  insecureSkipTLSVerify: true,

  thresholds: {
    http_req_failed: ['rate<0.01'],
    latency_weighted: ['p(95)<500'],
  },
};

const URL =
  'https://weighted.example.com/api/whoami';

const latencyWeighted = new Trend('latency_weighted');
const errorWeighted = new Rate('error_weighted');
const reqsWeighted = new Counter('reqs_weighted');

export default function () {
  const res = http.get(URL);

  const ok = check(res, {
    'weighted status is 200': (r) => r.status === 200,
  });

  latencyWeighted.add(res.timings.duration);
  errorWeighted.add(!ok);
  reqsWeighted.add(1);

  console.log(
    `status=${res.status} duration=${res.timings.duration}ms body=${res.body}`
  );

  sleep(1);
}
