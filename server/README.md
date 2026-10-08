# QuizMind server

Single Go binary: REST API, SSE progress stream, embedded admin UI and the question-generation workers. Design: [`../docs/architecture.md`](../docs/architecture.md).

```bash
cp config.example.yaml config.yaml      # optional; defaults work for local use
make run                                # http://127.0.0.1:8080; then add a model provider under "AI 与模型"
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

The admin token goes in `server/.token` (and any other environment in `server/.env`); neither is committed.


## Question reports

The apps let a learner report a question (`POST /api/v1/questions/{id}/flag`, optional `{"reason": ...}`).
Every report is a `question_flag` row; `question.flag_count` is the number of unresolved ones, and two of
them take a published question offline (`needs_review`, note `flagged by app users`). In the admin
review page, filter by "被反馈" to see every question with unresolved reports whatever its status;
"处理完毕" (`POST /admin/questions/{id}/dismiss-flags`) clears the reports and brings a question the
reports took offline back, and approve / reject settle them too.

## Question pictures

A stem, option or explanation may contain pictures (UML diagrams, flow charts), written
`![alt](media:<id>)`. Upload them from the question editor in the admin UI ("插入图片", or paste a
screenshot), or for hand-written material let devseed upload them: relative image paths in the
lecture notes and the questions JSON are replaced by `media:` references (`devseed -images <dir>`;
the default is the folder of `-doc`). Pictures are stored in `app.db` (PNG, JPEG, GIF, WebP, up to
5 MB, de-duplicated by content) and served at `GET /api/v1/media/{id}`. Back up `app.db` accordingly.

## Models

Providers (Anthropic or OpenAI-compatible endpoint + key), models, and which model plays which role
are set up on the admin UI's "AI 与模型" page and stored in the database (`llm_provider`, `llm_model`,
and the `llm_roles` / `llm_limits` entries of `app_setting`). Saving applies immediately; no restart.
Without a model for the `generator` role the server runs but generation jobs fail.

| Role | Used for | Protocol |
|---|---|---|
| `generator` | question generation from documents | either |
| `validator` | independent answer check (reserved) | either |
| `agent` | study / question-writing assistant | Anthropic only |
| `explain` | AI explanations, called by the apps themselves | OpenAI-compatible only |

An Anthropic-protocol endpoint without structured outputs is detected automatically and asked with the
schema in the prompt instead. The OpenAI-compatible client tries `json_schema`, then `json_object`,
then a plain prompt, and remembers the first the endpoint accepts.

Upgrading from a version that read `config.yaml`: the old `llm:` section and the key in the environment
variable it named, plus the saved AI-explanation endpoint, are imported once on the first start.

## AI explanations

The quiz app (Flutter) can ask an LLM to explain a question. The app calls an
OpenAI-compatible endpoint itself; the server hands it the connection details of the model bound to the
`explain` role (`GET /api/v1/ai/config`, needs the access token). Switch the feature on and set the token
on the admin UI's "AI 解读" tab. Saved explanations sync through
`/api/v1/sync/notes`. Back up `app.db` like any secret: it holds the API keys.
