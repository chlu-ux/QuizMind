# QuizMind admin

Vue 3 + Vite + TypeScript + Pinia + Element Plus. In production it is built into `../server/web/dist` and served by the Go binary, so there is no separate deployment.

```bash
npm install
npm run dev        # http://localhost:5173, proxies /admin to 127.0.0.1:8080
npm test           # unit tests (quote highlighting)
npm run typecheck
```

From `../server`, `make admin` builds this app and embeds it in the server binary.

Pages: 文档 (upload, live progress), 审核 (review with source highlighting; shortcuts J/K A R E), 题库, 任务, 用量.
Live updates use one `EventSource` (`/admin/events`); the access token is sent as a query parameter because `EventSource` cannot set headers.
