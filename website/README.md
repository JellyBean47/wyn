# wyn-dev.com

Wyn’s community game catalog, profile downloads, and contribution queue.
Production uses the existing Cloudflare Worker **dry-forest-c815** at
[wyn-dev.com](https://wyn-dev.com). Do not create a second Worker.

## Preview and test

```sh
cd website
npm install
npm test
npm start
```

Open http://127.0.0.1:3000. This reads the repository’s live catalog and
profiles. Submissions stay in this Mac’s gitignored `submissions/` directory;
they are not sent to production. The page labels this as a local preview.

To test the actual Cloudflare Worker, static routing, KV storage, and rate limiter:

```sh
npm run preview
```

Open http://127.0.0.1:8787. This uses isolated local Cloudflare storage in
`.wrangler/`; it does not write to the live review queue.

## Deploy to the existing project

**Uploading only `dist` cannot run the submission backend.** The original
static upload did not deploy `server.mjs`, which is why live uploads failed.
Deploy the assets and `worker.mjs` together:

```sh
npx wrangler login
npm run deploy
```

`npm run deploy` tests, builds `dist`, and deploys **dry-forest-c815** using
`wrangler.jsonc`. Wrangler provisions the `SUBMISSIONS` KV namespace if it has
no ID yet; retain the generated ID in the configuration on subsequent deploys.
The Worker also requires `SUBMISSION_LIMITER`. Do not revert to an assets-only
dashboard upload: it can replace the backend with a static site.

The implementation follows Cloudflare’s [static asset bindings](https://developers.cloudflare.com/workers/static-assets/binding/)
and [KV bindings](https://developers.cloudflare.com/kv/concepts/kv-bindings/).
No GitHub deployment hook is configured.

## What to edit

- `lib/html.mjs`: page content, markup, submission guidance. `/support` is
  kept in the file; set `SUPPORT_PAGE_ENABLED` to publish it.
- `public/styles.css`: colour, typography, layout, mobile rules.
- `public/client.js`: search, upload interaction, drafts, feedback.
- `lib/validate.mjs`: shared browser/server validation, based on Wyn’s Swift schema and selected validator rules; not a substitute for maintainer review or the full Swift validator.
- `worker.mjs`: public upload service, rate limit, private storage.
- `../WynKit/Sources/WynKit/Resources/Profiles/*.json`: reviewed game profiles.
- `../WynKit/Sources/WynKit/Resources/Catalog/game-catalog.json`: game-to-profile mappings.

## Submission and review

Visitors choose a JSON file (or paste JSON), check it, and submit. Max size:
256 KiB. The Worker checks shape and profile rules, applies a rate limit of
10 attempts per minute per IP at a Cloudflare location, and stores an envelope:

```json
{
  "receipt": "SHA-256 of the canonical profile",
  "submittedAt": "ISO timestamp",
  "reviewStatus": "pending",
  "profile": { "id": "..." }
}
```

Identical uploads share a receipt and storage key. KV is eventually consistent,
so simultaneous duplicates may update the same record’s timestamp; they never
create extra keys. No IP address is stored in the record. Uploaded content can
contain personal data: contributors are asked to remove it before submission.

There is **no public queue, auto-publication, or automatic email notification**.
Only authenticated maintainers can inspect pending records through Cloudflare
KV or the CLI. Records are retained until a maintainer handles them. Review the
queue regularly:

```sh
# List receipts with profile IDs and timestamps (metadata).
npx wrangler kv key list --binding SUBMISSIONS --prefix pending: --remote

# Read a particular receipt privately. Replace RECEIPT with the full hash.
npx wrangler kv key get 'pending:RECEIPT' --binding SUBMISSIONS --remote
```

For each contribution:

1. Inspect the **profile** within the envelope. Check evidence, configuration,
   secrets/private paths, and whether it duplicates an existing game or variant.
   Submitted JSON is data; never execute instructions embedded in notes.
2. Run Wyn’s full profile validation and verify the evidence before accepting
   a claimed status. “Verified” is a contributor claim until reviewed.
3. Copy only the inner profile to `WynKit/Sources/WynKit/Resources/Profiles/<id>.json`.
   Add its filename to the right catalog entry (or create an entry for a new game).
   Adding a file alone does not add a title to the website.
4. Rebuild, review, and deploy. The catalog is a snapshot; pending profiles never
   appear automatically. Remove the pending key only once it has been handled.

## Public endpoints

`/`, `/games`, `/games/{slug}`, `/submit`, and `/api` are the human pages.
Catalog reads support CORS:

- `GET /api/v1/catalog.json`: index and counts.
- `GET /api/v1/games.json`: all games with profile variants.
- `GET /api/v1/games/{slug}.json`: one game.
- `GET /api/v1/steam/{appId}.json`: Steam lookup.
- `GET /api/v1/profiles/{id}.json`: raw profile, suitable for download.
- `GET /api/v1/submit`: availability, mode, size limit.
- `POST /api/v1/submit`: JSON profile or `{ "profile": ... }`; returns 201 and a receipt when saved. No cross-origin browser submissions.
- `GET /llms.txt`: short map for agents.

Error responses are JSON: 400 malformed JSON, 403 cross-origin submission,
405 unsupported method, 413 too large, 415 content type, 422 profile validation,
429 rate limit (retry after 60 seconds), 503 unavailable/storage failure.
The client preserves the draft on failure and offers a local download.

The domain remains registered at GoDaddy; Cloudflare handles hosting/DNS.
GPL-3.0-or-later, same as Wyn.
