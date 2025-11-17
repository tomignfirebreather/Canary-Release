import http from 'k6/http';
import { check, sleep } from 'k6';

export let options = {
  stages: [
    { duration: '30s', target: 10 },   // aumenta gradualmente a 10 usuarios
    { duration: '1m', target: 10 },    // mantiene 10 usuarios durante 1 min
    { duration: '10s', target: 0 },    // reduce la carga
  ],
  thresholds: {
    http_req_duration: ['p(95)<500'],  // 95% de las respuestas < 500ms
  },
};

export default function () {
  const res = http.get('http://127.0.0.1:65508');  // 👈 reemplazá con la URL real del servicio
  check(res, {
    'status es 200': (r) => r.status === 200,
  });
  sleep(1);
}
