import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Rate, Counter } from 'k6/metrics';

export const options = {
  vus: 400,
  duration: '2m',
  insecureSkipTLSVerify: true,
};

const endpoints = {
  v1: 'https://banking-api-v1-rhcl-apps.apps.example.com/api/whoami',
  v2: 'https://banking-api-v2-rhcl-apps.apps.example.com/api/whoami',
  weighted: 'https://weighted.example.com/api/whoami',
};

const latencyV1 = new Trend('latency_v1');
const latencyV2 = new Trend('latency_v2');
const latencyWeighted = new Trend('latency_weighted');

const errorV1 = new Rate('error_v1');
const errorV2 = new Rate('error_v2');
const errorWeighted = new Rate('error_weighted');

const reqsV1 = new Counter('reqs_v1');
const reqsV2 = new Counter('reqs_v2');
const reqsWeighted = new Counter('reqs_weighted');

function testEndpoint(name, url) {
  const res = http.get(url, {
    tags: { endpoint: name },
  });

  const ok = check(res, {
    [`${name} status is 200`]: (r) => r.status === 200,
  });

  if (name === 'v1') {
    latencyV1.add(res.timings.duration);
    errorV1.add(!ok);
    reqsV1.add(1);
  }

  if (name === 'v2') {
    latencyV2.add(res.timings.duration);
    errorV2.add(!ok);
    reqsV2.add(1);
  }

  if (name === 'weighted') {
    latencyWeighted.add(res.timings.duration);
    errorWeighted.add(!ok);
    reqsWeighted.add(1);
  }
}

export default function () {
  testEndpoint('v1', endpoints.v1);
  testEndpoint('v2', endpoints.v2);
  testEndpoint('weighted', endpoints.weighted);

  sleep(1);
}
