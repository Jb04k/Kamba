Kamba
Reliability infrastructure for Safaricom Daraja callbacks.

Kamba sits between Safaricom's Daraja API and your application. It receives Daraja's callbacks, guarantees they're processed exactly once even when Safaricom retries or duplicates them, recovers payments whose callback never arrives at all, and forwards a clean, signed, replayable event to your app — so your team never has to hand-roll this again.

Status: 🚧 early-stage portfolio/infrastructure project, built against the Daraja sandbox. Do not point it at production credentials or real customer data yet.

Why this exists
Daraja handles the payment side of an integration reasonably well. What it does not give you is a reliable way to find out what happened:

Daraja does not sign its callbacks. Unlike Stripe, GitHub, or Shopify, there is no HMAC signature header to verify a callback actually came from Safaricom and wasn't spoofed or replayed.
Duplicate callbacks are a documented behavior, not an edge case. Safaricom's own retry logic means the same STK Push or C2B transaction can call your endpoint more than once — you're expected to build deduplication yourself, every time, from a blog post.
Callbacks can simply never arrive. Network issues, timeouts, or Safaricom-side failures mean a payment can complete on Safaricom's end with your application never finding out — unless you separately poll for it.
Access tokens expire hourly and must be silently refreshed without interrupting in-flight requests.
The sandbox itself is unreliable enough that developers routinely build workaround tooling just to get a stable dev loop.
Every team integrating Daraja directly ends up rebuilding the same fragile pieces: an idempotency check, a raw-payload log table, a reconciliation cron job, and a token-refresh wrapper — usually copied from a tutorial, rarely tested under real concurrency. Kamba exists to build that layer once, properly, so you don't have to.

What Kamba is — and isn't
Kamba is a webhook reliability and reconciliation gateway, not a Daraja API wrapper.

A Daraja wrapper	Kamba
Simplifies calling Daraja (STKPushRequest, C2BRegisterURL, etc.)	Simplifies and secures what happens after Daraja calls you back
Solves "how do I send a request"	Solves "how do I trust, dedupe, and never lose a response"
Doesn't touch reliability, retries, or reconciliation	Idempotency, retries, signing, and reconciliation are the entire point
Kamba does not replace Daraja, does not process payments itself, and is not a payment gateway or PSP. It's the missing reliability layer that sits in front of your application's own business logic.

How it works
text
                        Safaricom Daraja
                               │
                    STK Push / C2B callback
                    (unsigned, possibly duplicated,
                     possibly never sent at all)
                               │
                               ▼
                     ┌───────────────────┐
                     │       KAMBA        │
                     │                    │
                     │  1. Ingest          │  raw payload stored immutably,
                     │  2. Deduplicate      │  idempotency enforced at the DB layer
                     │  3. Normalize        │  provider payload → canonical event
                     │  4. Sign & deliver    │  HMAC-signed, retried with backoff
                     │  5. Reconcile         │  polls Transaction Status API for
                     │     (background)      │  anything that never called back
                     └─────────┬──────────┘
                               │
                     normalized, signed event
                               │
                     ┌─────────┴─────────┐
                     ▼                   ▼
              Your application    Dashboard / API
              (any stack — Django,   (event log, delivery
               Laravel, Node, etc.)   status, manual replay)
Kamba itself is built in Python (Django + Django REST Framework); the applications that consume its normalized events can be written in anything, since delivery happens over plain signed HTTP.

Core concepts
Ingestion. A dedicated, unguessable per-connection URL receives Daraja's STK Push and C2B (Validation/Confirmation) callbacks. The endpoint does the minimum work needed to return 200 fast — Safaricom's retry behavior punishes slow or non-responding endpoints — and hands everything else to a background worker.

Idempotency. Every raw event is keyed on (connection, provider_transaction_id) with a database-level uniqueness constraint, not an application-level check-then-insert. This is what actually holds under concurrent duplicate callbacks, which is the failure mode Daraja is known to produce.

Normalization. Daraja's STK Push and C2B payloads have different shapes (and the STK Push payload nests a CallbackMetadata item list that differs between success and failure). Kamba normalizes both into one canonical event schema so your application never has to branch on payload shape.

Reconciliation. Retries only help once a callback has arrived. They do nothing for a callback that never arrives at all — Safaricom's own integration guidance explicitly recommends polling the Transaction Status API for anything left pending, rather than trusting callbacks alone. Kamba runs this as a background sweep and injects a recovered event for anything it finds.

Signing. Daraja doesn't sign what it sends you, so Kamba signs what it forwards to you — HMAC-SHA256 over a timestamp and payload, so your application can verify a delivery genuinely came from Kamba and reject anything outside a replay window.

Observability & replay. Every ingestion and delivery attempt is logged, queryable, and individually replayable — so a failure during development or an incident doesn't mean the event is gone.

Architecture
text
kamba/
├── api/                 # DRF viewsets — connections, events, deliveries, webhook-endpoints
├── ingestion/            # public callback endpoint, raw payload storage, idempotency
├── delivery/             # normalization, HMAC signing, retry/backoff worker
├── reconciliation/        # scheduled Transaction Status API polling worker
├── providers/
│   └── daraja/           # Daraja-specific client: OAuth token cache/refresh,
│                          # STK Push + C2B payload parsing, Transaction Status calls
└── core/                 # shared models: connections, events, delivery_attempts
Backend: Django + Django REST Framework
Database: PostgreSQL — source of truth for connections, raw events, canonical events, delivery attempts, and reconciliation runs
Queue/workers: Redis + Celery — ingestion processing, delivery, and scheduled reconciliation sweeps run as separate queues
Deployment: Docker Compose locally; a single deployable web process + worker process in production (a modular monolith, not microservices — there's no independent-scaling need at this stage to justify the operational cost of splitting services)
Getting started
bash
git clone https://github.com/<Jb04k>/kamba.git
cd kamba
cp .env.example .env        # add your Daraja sandbox credentials
docker-compose up
You'll need a Daraja sandbox app from the Safaricom developer portal (consumer key, consumer secret, and a shortcode) and a tunnel such as ngrok so Safaricom's sandbox can reach your local ingestion URL — Daraja cannot call localhost directly.

bash
# once running, register a connection and get your ingestion URL
curl -X POST http://localhost:8000/api/v1/connections/ \
  -H "Authorization: Bearer <your-api-key>" \
  -d '{"provider": "daraja", "shortcode": "174379"}'
The response includes a unique ingestion URL — point your Daraja sandbox app's callback URL at it (via your ngrok tunnel) and trigger a test STK Push to see an event flow through end to end.

API overview
Method	Endpoint	Purpose
POST	/api/v1/connections/	Register a Daraja connection, get back an ingestion URL
POST	/ingest/{provider}/{connection_id}/{token}/	Public endpoint Daraja calls back to (not called by you)
GET	/api/v1/events/	List canonical payment events — filterable by status, connection, date
GET	/api/v1/events/{id}/	Event detail, including the raw payload and full delivery history
POST	/api/v1/events/{id}/replay/	Manually re-trigger delivery of an event
GET	/api/v1/deliveries/?event_id=	Delivery attempt history for a given event
POST	/api/v1/webhook-endpoints/	Register the URL Kamba should forward normalized events to
GET	/api/v1/reconciliation-runs/	History of reconciliation sweeps and recovered events
Full request/response schemas are in docs/api.md (coming as the API stabilizes).

Security
Daraja callback payloads contain personal and financial data (phone numbers, amounts, transaction IDs), so this is treated as sensitive by default:

Ingestion URLs are high-entropy, unguessable, and rotatable per connection — the only practical substitute for the header-based auth Daraja doesn't support on outbound calls.
Daraja credentials and webhook secrets are encrypted at rest, never returned by the API after creation.
Phone numbers (MSISDN) are masked in API responses and stored encrypted.
Outbound deliveries to your application are HMAC-signed with a timestamp, so you can verify authenticity and reject replayed requests outside a skew window.
Every endpoint is scoped to the authenticated connection/merchant — there is no cross-tenant read path.
Never point Kamba at production Daraja credentials or real customer transaction data while the project is at this stage.

Roadmap
Phase 1 — Ingestion & idempotency (foundation — nothing else works without this)

 Daraja STK Push + C2B callback endpoint
 Raw payload persistence
 Database-level idempotency, proven under concurrent duplicate callbacks
 Initial test suite
Phase 2 — Delivery

 Canonical event normalization
 HMAC-signed outbound delivery
 Retry with exponential backoff, full attempt logging
Phase 3 — Reconciliation

 Transaction Status API polling worker
 Recovered-event injection for callbacks that never arrive
 Token refresh/caching for the Daraja OAuth flow
Phase 4 — Developer surface

 Full REST API (connections, events, deliveries, replay)
 Rate limiting
 Silent-connection alerting
 Minimal status dashboard
Phase 5 — Beyond Daraja

 Provider-adapter abstraction proven against a second provider (MTN MoMo / Airtel Money)
 SDKs for common consuming stacks (Python, Node)
Research questions this project is also trying to answer
How often, in practice, do Daraja callbacks arrive duplicated versus not at all?
How well does reconciliation-via-polling actually recover "lost" payments within a reasonable SLA window?
Does the same ingestion/reconciliation architecture generalize cleanly to MTN MoMo and Airtel Money, or do their failure modes diverge enough to break the abstraction?
Contributing
Issues and discussion are welcome. Before proposing a larger feature, open an issue describing the problem, the proposed approach, alternatives considered, and how it would be tested — this project is intentionally built experiment-first rather than speculatively.

License
License to be added as the project matures.




