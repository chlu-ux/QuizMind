# QuizMind server

Single Go binary: REST API, SSE progress stream, embedded admin UI and the question-generation workers. Design: [`../docs/architecture.md`](../docs/architecture.md).

```bash
cp config.example.yaml config.yaml      # optional; defaults work for local use
export ANTHROPIC_API_KEY=sk-ant-...     # without it the server runs but generation jobs fail
make run                                # http://127.0.0.1:8080
make test                               # go test -race ./...
make sqlc                               # after editing internal/db/migrations or queries
```

- Upload a Markdown file: `curl -F bank_id=<id> -F file=@notes.md localhost:8080/admin/documents`
- The quiz API (`/api/v1`) needs no token. The admin API (`/admin`) is guarded: listening on anything other than loopback requires `QUIZMIND_TOKEN`; send it as `Authorization: Bearer <token>`.
- Data lives in `data_dir/app.db` (SQLite, WAL). Back it up with `sqlite3 app.db "VACUUM INTO 'backup.db'"`.
