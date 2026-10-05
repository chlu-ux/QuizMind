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

## Running in the background

```bash
./run.sh                 # rebuild and restart
./run.sh restart -w      # also rebuild the admin and phone web UIs
./run.sh start|stop|status|logs
```

Secrets go in `server/.env` (e.g. `ANTHROPIC_API_KEY=...`) and `server/.token`; neither is committed.


## Question reports

The apps let a learner report a question (`POST /api/v1/questions/{id}/flag`, optional `{"reason": ...}`).
Every report is a `question_flag` row; `question.flag_count` is the number of unresolved ones, and two of
them take a published question offline (`needs_review`, note `flagged by app users`). In the admin
review page, filter by "被反馈" to see every question with unresolved reports whatever its status;
"处理完毕" (`POST /admin/questions/{id}/dismiss-flags`) clears the reports and brings a question the
reports took offline back, and approve / reject settle them too.

## AI explanations

The quiz app (Flutter) can ask an LLM to explain a question. The app calls an
OpenAI-compatible endpoint itself; the server stores the endpoint, key and an access
token in the database and hands them to the app (`GET /api/v1/ai/config`, needs the
token). Set them up on the admin UI's "AI 解读" page. Saved explanations sync through
`/api/v1/sync/notes`. Back up `app.db` like any secret: it now holds that API key.
