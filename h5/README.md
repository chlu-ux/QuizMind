# QuizMind H5

Phone-first web app for practising the published question banks. Vue 3 + Vite + TypeScript, data kept in IndexedDB, synced with the Go server's `/api/v1/*` (see `../api/openapi.yaml`).

```bash
npm ci
npm test                # logic tests (fake IndexedDB)
npm run dev             # http://localhost:5174/m/ , proxies /api to 127.0.0.1:8080
make -C ../server h5    # build into server/web/dist/m and rebuild the binary
```

The server serves it at `/m/`. On a phone on the same Wi-Fi open `http://<Mac LAN IP>:8080/m/`
(the server must listen on `0.0.0.0:8080` with `QUIZMIND_TOKEN` set), then enter the token under 设置.

Keyboard on desktop: `1`–`4` choose, `Enter` submit / next, `J` or `→` next, `K` or `←` previous.

Single-choice options are shuffled each time a quiz session starts (and stay put when you step back to a question). Judge questions keep 正确 / 错误 in a fixed order. Grading and the stored attempts always use the question's original option indexes, so shuffling never changes what the server sees; `1`–`4` pick by the position shown on screen.

AI 助手：设置页「AI 助手」填后台「AI 解读」里设置的访问令牌（只存在这台设备上），之后题库页、讲义页和答题解析下会出现「问 AI」「AI 出题」「追问 AI」。设计见 `../docs/agent-design.md`。
