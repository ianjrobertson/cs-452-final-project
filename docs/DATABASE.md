# Oracle — Database Connection Plan

## Environments at a Glance

| Env | Database | How configured |
|---|---|---|
| `dev` | Local Postgres (`oracle_dev`) | Hardcoded in `config/dev.exs` |
| `test` | Local Postgres (`oracle_test`) | Hardcoded in `config/test.exs` |
| `prod` | Supabase (Postgres 15) | `DATABASE_URL` env var, read in `config/runtime.exs` |

---

## Local Development (dev + test)

Both environments hit a local Postgres instance with default credentials. No env vars needed.

```
host:     localhost
user:     postgres
password: postgres
database: oracle_dev   (oracle_test for test env)
```

**pgvector** must be installed locally for embeddings to work:

```bash
# macOS — Homebrew Postgres
brew install pgvector

# macOS — Postgres.app (pgvector bundled, just enable it)
psql -d oracle_dev -c "CREATE EXTENSION IF NOT EXISTS vector;"
```

After enabling the extension, run migrations normally:

```bash
cd oracle
mix ecto.migrate
```

---

## Production (Supabase)

Supabase is a hosted Postgres provider — the app connects to it as a standard Postgres database via `DATABASE_URL`. pgvector is available as a first-party extension.

### 1. Create a Supabase project

Sign in at [supabase.com](https://supabase.com), create a new project, and wait for provisioning.

### 2. Enable pgvector

Dashboard → Database → Extensions → search `vector` → Enable.

This must be done before running migrations (the `signals` table requires the `vector` column type).

### 3. Get the connection string

Dashboard → Project Settings → Database → Connection string → **URI** tab.

Use the **direct connection** (port 5432), not the pooler. The app uses long-lived GenServer connections and pgvector queries — the transaction pooler (port 6543) does not support these.

```
postgresql://postgres.[project-ref]:[password]@aws-0-[region].supabase.com:5432/postgres
```

### 4. Enable SSL in runtime.exs

Supabase requires SSL. Uncomment the `ssl: true` line in `oracle/config/runtime.exs`:

```elixir
config :oracle, Oracle.Repo,
  ssl: true,            # uncomment this line
  url: database_url,
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
  socket_options: maybe_ipv6
```

### 5. Set environment variables

```bash
DATABASE_URL=postgresql://postgres.[ref]:[password]@aws-0-[region].supabase.com:5432/postgres
POOL_SIZE=10   # Supabase free tier: 60 connection max; keep this ≤ 10
```

### 6. Run migrations against Supabase

```bash
cd oracle
DATABASE_URL="postgresql://..." mix ecto.migrate
```

---

## Connection Modes (Supabase reference)

| Mode | Port | Supports pgvector | Supports prepared statements | Use for |
|---|---|---|---|---|
| Direct | 5432 | Yes | Yes | This app (prod) |
| Pooler — Session | 5432 (via PgBouncer) | Yes | Yes | Alternative if direct hits connection limits |
| Pooler — Transaction | 6543 | Yes | **No** | Serverless / short-lived only |

**This app must use direct or session pooler** — the Broadway pipeline and GenServer agents hold connections open, and Ecto uses prepared statements by default.

---

## Supabase Local (optional, Docker-based)

If you want a local environment that more closely mirrors Supabase prod (e.g., to test row-level security or Supabase Auth), the Supabase CLI spins up a full stack locally.

```bash
brew install supabase/tap/supabase
cd oracle
supabase init    # creates supabase/ config dir (commit this)
supabase start   # pulls Docker images (~1 GB), starts local stack
```

The CLI will print local credentials:

```
DB URL:  postgresql://postgres:postgres@127.0.0.1:54322/postgres
Studio:  http://127.0.0.1:54323
```

To point dev at the local Supabase stack instead of system Postgres, set in your shell:

```bash
export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
```

And update `dev.exs` to prefer the env var:

```elixir
config :oracle, Oracle.Repo,
  url: System.get_env("DATABASE_URL") || "postgresql://postgres:postgres@localhost:54322/postgres",
  pool_size: 10
```

Then run `mix ecto.migrate` as usual — the local Supabase stack is just Postgres.

**When to use Supabase Local vs plain local Postgres:**

- For this project, plain local Postgres is simpler and sufficient — no Supabase-specific features (Auth, Storage, RLS) are used.
- Use Supabase Local only if you want to validate prod behavior (SSL, connection limits, extension versions) before deploying.

---

## Checklist: First-time Supabase prod setup

- [ ] Create Supabase project
- [ ] Enable `vector` extension in Dashboard → Extensions
- [ ] Grab direct connection string (port 5432)
- [ ] Uncomment `ssl: true` in `config/runtime.exs`
- [ ] Set `DATABASE_URL` and `POOL_SIZE` in your deployment env
- [ ] Run `mix ecto.migrate` against the Supabase DB
- [ ] Verify `signals.embedding` column type is `vector(1536)` in Supabase Table Editor
