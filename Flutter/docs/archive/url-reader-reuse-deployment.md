# URL Reader Service Reference (Legacy Client Integration)

> Current Flutter link import no longer calls this service directly. The app
> uses the authenticated 39 Workspace `note-ingestions` API, and 39 owns URL
> parsing, polling, HNote promotion, and persistence. This document remains a
> server-side implementation and deployment reference only.

Last verified: 2026-08-14

### Physical-device incident evidence: 2026-09-17 CST

The inventory below describes the legacy standalone 101 service, not proof
that the current 39 Worker has the same dependencies. A physical-device audit
found accepted XHS ingestions failing on 39 with `PYTHON_VERSION_UNSUPPORTED`:
its release-local XHS venv and downloader were absent and the bridge fell back
to Python 3.10.12. The embedded Go command client also filters child-process
environment variables, so a standalone-service environment setting alone is
not an embedded-runtime fix. See
`Flutter/reports/link-import-device-audit-20260917.md` for evidence, client
changes, and the server remediation still requiring authorization.

## Purpose

`local-url-reader` is a synchronous public-link analysis service. It accepts a
single public HTTP(S) URL, selects a platform adapter, returns a normalized
result, and optionally downloads media and calls the locally installed Tencent
recording-transcription modules. It has no Agent, Redis, Celery, task queue,
job creation, or polling API.

This guide records the real 101 deployment and explains how to reproduce the
same functionality on another host, including the 39 server. It does not
perform any deployment on 39.

## Current 101 Inventory

| Item | Current value | Purpose |
| --- | --- | --- |
| Host | `101.201.70.18` | Existing URL Reader host |
| Wrapper source | `/opt/url-reader` | Main Node.js service source |
| Service unit | `/etc/systemd/system/url-reader.service` | Current process supervisor |
| Current listener | `0.0.0.0:80` | Explicit temporary direct-IP deployment |
| Local ASR project | `/opt/tencent-flutter-asr-gateway` | Tencent transcription modules reused by the wrapper |
| Credential file | `/opt/SecretKey.csv` | Read only by the local ASR project; never copy its contents to Git or app configuration |
| Main entrypoint | `/opt/url-reader/src/index.mjs` | `serve` and terminal `parse` commands |
| API contract | `/opt/url-reader/docs/frontend-backend-integration.md` | Request, response, error, and deployment details |

The current direct endpoint is `http://101.201.70.18`. It exists only because
this deployment explicitly authorized a fixed-IP HTTP exception. It is not the
recommended reusable deployment form: it has no TLS and transfers the input
link, consent version, and parsed output in cleartext.

## Functional Boundary

```text
Flutter link import
  -> POST /api/v1/parse
  -> URL/DNS public-address guard
  -> platform adapter or generic web adapter
  -> normalized result
  -> optional yt-dlp + FFmpeg media preparation
  -> local Tencent ASR modules
  -> synchronous final result
```

Supported adapter paths on 101 are Bilibili, Douyin, XiaoHongShu, WeChat, and
generic public web content. The API returns a `result` object containing the
recognized platform, content type, canonical URL, optional title/author/text,
optional transcript, cached image paths, and warnings. Cached images are
served from `/api/v1/assets/<generated-name>`; they are not Base64 payloads.

The result is source material only. In particular, `title` is part of the
original asset content, alongside the source URL, author, publication time,
body, transcript, and images. A client must display and persist it as original
content; it must not map `title`, `text`, or `transcript` into an outline,
germination, summary, or other generated knowledge field. URL Reader does not
produce those fields. Only the 39 business service may generate and own
outlines, germinations, and other derived knowledge content.

Keep these compatibility rules unchanged when moving the service:

- Preserve `POST /api/v1/parse`, `GET /healthz`, and
  `GET /api/v1/assets/<generated-name>` paths.
- Parsing is synchronous. A client that requests `transcribe: true` waits for
  final text in the same response; do not replace it with a job or polling API.
- A transcription request must include a valid `consentVersion`, unless the
  server supplies `URL_READER_DEFAULT_CONSENT_VERSION`.
- Preserve URL safety checks: only public HTTP(S) URLs on ports 80 or 443, no
  user info, and no private, loopback, metadata, or special addresses.
- Preserve the 22-minute mobile-client timeout. The server's whole-request
  timeout is configurable separately with `URL_READER_REQUEST_TIMEOUT_MS`.
- Do not move HNote, Workspace, auth, chat, upload, or any other 39 business
  responsibility into this service. It is only a link-analysis service.
- Do not add outline, germination, summary, or knowledge-generation behavior
  to this service. Those remain exclusive 39 responsibilities.

## Source Map

Use these paths on 101 to inspect the implementation directly:

| Path | Responsibility |
| --- | --- |
| `/opt/url-reader/src/index.mjs` | CLI and HTTP service startup |
| `/opt/url-reader/src/lib/server.mjs` | HTTP routes, request parsing, response/error envelope |
| `/opt/url-reader/src/lib/pipeline.mjs` | Synchronous parse and transcription flow |
| `/opt/url-reader/src/lib/url-guard.mjs` | Public-address, redirect, and DNS-rebinding protections |
| `/opt/url-reader/src/lib/local-asr.mjs` | Narrow dynamic bridge to the Tencent ASR project |
| `/opt/url-reader/src/lib/media.mjs` | Media download and FFmpeg audio preparation |
| `/opt/url-reader/src/lib/asset-store.mjs` | Short-lived parsed image cache |
| `/opt/url-reader/src/adapters/` | Bilibili, Douyin, WeChat, XiaoHongShu, and generic web adapters |
| `/opt/url-reader/test/` | Node test suite |
| `/opt/url-reader/scripts/` | Python and XHS runtime bootstrap scripts |
| `/opt/url-reader/third_party/UPSTREAMS.md` | Upstream revisions and licenses |
| `/opt/url-reader/.env.example` | Supported environment variables, without secrets |

## Runtime Requirements

The verified 101 runtime is Node.js `v22.23.1` and npm `10.9.8`. The wrapper
declares Node.js 20+ as its minimum. A compatible target host needs:

- Node.js 20 or newer and npm.
- Python 3.10 or newer for the basic WeChat and generic HTML bridges.
- Python 3.12 for the isolated XHS runtime.
- `ffmpeg` and `ffprobe`.
- Google Chrome or Chromium for public Douyin video resolution.
- The Tencent ASR project and its protected credentials when transcription is
  required. The current credential-file default is `/opt/SecretKey.csv`; never
  copy secret values into Git, systemd configuration, or Flutter.

The wrapper itself has no npm package dependency installation step, but its
ignored local runtime and upstream directories must exist. On a fresh clone,
run:

```bash
cd /opt/url-reader
./scripts/bootstrap-python-deps.sh
./scripts/bootstrap-xhs-runtime.sh
```

Generic web parsing has a standard-library fallback when Crawl4AI's optional
browser-oriented Python dependencies are absent. Bilibili, Douyin, and XHS
must be installed for functional parity with 101. Enable the separately
provisioned ASR dependency only when transcription is required.

## Git And Open Source Status

The wrapper root on 101 is initialized as Git `main` but has **no commit and no
remote**. There is no existing public GitHub or GitLab URL for
`local-url-reader`; do not invent one in deployment configuration or release
notes.

Before reusing the wrapper on 39, publish a controlled source repository from
101. First review `.gitignore`, ensure `.env`, `.runtime/`, `runtime/`,
`data/`, `node_modules/`, credentials, and generated media remain excluded,
then create the initial immutable release:

```bash
cd /opt/url-reader
git add -A
git status
git commit -m "Initial local URL Reader release"
git remote add origin https://github.com/<organization>/local-url-reader.git
git push -u origin main
git tag -a v0.1.0 -m "Verified 101 URL Reader deployment"
git push origin v0.1.0
```

Replace the example URL with the approved organization repository. Deploy 39
by tag or commit SHA, never by an unreviewed working tree.

The wrapper uses the following public upstream projects through narrow local
adapters. Their source code is intentionally ignored by the wrapper root, so a
new deployment must clone them at the pinned revisions from
`third_party/UPSTREAMS.md` or restore an approved build artifact.

| Upstream | Public repository | Pinned 101 revision | License |
| --- | --- | --- | --- |
| WeChat parser | [bzd6661/wechat-article-for-ai](https://github.com/bzd6661/wechat-article-for-ai) | `69de9e413cca3fe6b770c40a4dec204afd5b2b3c` | MIT |
| XiaoHongShu parser | [JoeanAmier/XHS-Downloader](https://github.com/JoeanAmier/XHS-Downloader) | `cfc064f24621bf75da9f6e33d084ebcfa7f4a98e` | GPL-3.0 |
| Generic web parser | [unclecode/crawl4ai](https://github.com/unclecode/crawl4ai) | `7e801521428ee12509994d39151006f64055ebe3` | Apache-2.0 |
| Media downloader | [yt-dlp/yt-dlp](https://github.com/yt-dlp/yt-dlp) | `5d6b8c8cd19785c3086ae3a9ec618c45e25eb3bc` | Unlicense |

Review the GPL-3.0 obligations of XHS-Downloader before distributing a bundled
artifact or changing the adapter boundary.

The transcription runtime on 101 is separately managed and is not part of the
URL Reader Git repository. When transcription is needed on another host,
provision the approved private runtime or artifact separately, with its
credentials kept outside the checkout.

## Recommended 39 Deployment

Do not copy the current 101 direct-IP HTTP exposure to 39. Keep URL Reader on
39 loopback and put a TLS reverse proxy in front of it. This preserves parsing
behavior while restoring encrypted transport and avoiding a second public
service port.

### 1. Install A Versioned Release

After publishing the wrapper repository, use a dedicated directory on 39. The
following commands are a deployment template, not commands already run on 39:

```bash
git clone https://github.com/<organization>/local-url-reader.git /opt/url-reader
cd /opt/url-reader
git checkout v0.1.0

mkdir -p third_party
git clone https://github.com/bzd6661/wechat-article-for-ai.git third_party/wechat-article-for-ai
git -C third_party/wechat-article-for-ai checkout 69de9e413cca3fe6b770c40a4dec204afd5b2b3c
git clone https://github.com/JoeanAmier/XHS-Downloader.git third_party/XHS-Downloader
git -C third_party/XHS-Downloader checkout cfc064f24621bf75da9f6e33d084ebcfa7f4a98e
git clone https://github.com/unclecode/crawl4ai.git third_party/crawl4ai
git -C third_party/crawl4ai checkout 7e801521428ee12509994d39151006f64055ebe3
git clone https://github.com/yt-dlp/yt-dlp.git third_party/yt-dlp
git -C third_party/yt-dlp checkout 5d6b8c8cd19785c3086ae3a9ec618c45e25eb3bc

./scripts/bootstrap-python-deps.sh
./scripts/bootstrap-xhs-runtime.sh
npm test
npm run check
```

Use a release-specific owner and permissions. When transcription is enabled,
its credential material belongs in a root-readable secret file outside the Git
checkout. Do not copy `/opt/SecretKey.csv` through source control, chat, shell
history, or client build variables.

### 2. Configure The Service

Create a protected environment file such as `/etc/url-reader.env`:

```dotenv
URL_READER_HOST=127.0.0.1
URL_READER_PORT=8788
# Set these only when transcription is deployed on this host.
# URL_READER_ASR_PROJECT_DIR=/opt/tencent-flutter-asr-gateway
# URL_READER_ASR_ENABLED=true
# URL_READER_ASR_REGION=ap-guangzhou
URL_READER_REQUEST_TIMEOUT_MS=1200000

# Optional only if the trusted server-side proxy injects this token.
# URL_READER_AUTH_TOKEN=<long-random-secret>
```

Keep `URL_READER_ALLOW_PUBLIC_LISTEN` absent or false on 39. Configure a
protected transcription credential path only when that optional runtime is
enabled.

Use a systemd unit similar to:

```ini
[Unit]
Description=Huahuo URL Reader
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/url-reader
Environment=NODE_ENV=production
EnvironmentFile=/etc/url-reader.env
ExecStart=/usr/bin/node /opt/url-reader/src/index.mjs serve
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Install it as `/etc/systemd/system/url-reader.service`, then validate before
publishing it:

```bash
systemctl daemon-reload
systemctl enable --now url-reader.service
systemctl is-active url-reader.service
curl --fail-with-body http://127.0.0.1:8788/healthz
```

### 3. Add An HTTPS Reverse Proxy

Add the following to the existing 39 HTTPS virtual host. Keep the URL Reader
prefix separate from the existing application routes. The trailing slash on
`proxy_pass` removes `/url-reader/` before the loopback service receives the
request.

```nginx
location = /url-reader {
    return 308 /url-reader/;
}

location ^~ /url-reader/ {
    proxy_pass http://127.0.0.1:8788/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_connect_timeout 15s;
    proxy_read_timeout 1320s;
    proxy_send_timeout 1320s;
    client_max_body_size 16k;
}
```

The Flutter URL Reader client intentionally sends no service Bearer Token. If
the service token is enabled later, an authenticated business backend or a
trusted server-side proxy must inject it. Do not embed that token in Flutter.

### 4. Point Flutter To The TLS Route

The app retains 39 as its main API. Only link parsing uses the independent URL
Reader base. Build the app with a TLS override after the proxy is live:

```bash
flutter build ios \
  --dart-define=HUAHUO_URL_READER_BASE_URL=https://<public-domain>/url-reader
```

Use the equivalent `--dart-define` for Android. Do not change
`HUAHUO_API_BASE_URL` or `HUAHUO_RECORDING_API_BASE_URL` as part of this
migration; they remain the established 39 business-service configuration.

## Verification And Rollback

Run these checks in order on the new host:

```bash
cd /opt/url-reader
npm test
npm run check
curl --fail-with-body http://127.0.0.1:8788/healthz
```

Then test the TLS route with a public article. A media request can create a
real transcription task and incur cost, so use it only with approved test
links and explicit consent:

```bash
curl --fail-with-body https://<public-domain>/url-reader/api/v1/parse \
  -H 'Content-Type: application/json' \
  --data '{"url":"https://b23.tv/igFRi76","transcribe":true,"consentVersion":"2026-08-v1"}'
```

Confirm a structured `result`, expected platform, and non-empty canonical URL
and title. Treat the returned title as original asset content, not an outline.
When a transcription was requested and succeeds, confirm a non-empty
transcript. Test image retrieval through the same prefix when `images` is
non-empty.

For rollback, switch the systemd `WorkingDirectory` to the previous tagged
release, restart `url-reader.service`, and reload the reverse proxy only after
its configuration test succeeds. Do not delete the previous release or its
runtime diagnostics until the rollback window has passed.

## Operations Notes

- `GET /healthz` has no caller token requirement and reports whether
  transcription support is enabled. It does not prove an external task.
- `transcribe: true` without `consentVersion` returns `CONSENT_REQUIRED` when
  no default consent version is configured.
- Transcription failures are returned as structured server errors. Inspect
  `journalctl -u url-reader.service` and protected runtime configuration
  without exposing secret values.
- The URL Reader is intentionally separate from the 39 business service. 39
  owns application authentication, Workspace/HNote persistence, uploads, and
  all other product APIs.
