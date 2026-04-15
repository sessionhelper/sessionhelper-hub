# Auth & Reverse Proxy Implementation Plan

Status: **Draft** | Last updated: 2026-04-07

This document covers the concrete steps to make the Session Helper frontend
publicly accessible with Discord OAuth, HTTPS, and environment isolation.

---

## 1. Recommended Stack

| Concern | Choice | Rationale |
|---|---|---|
| Reverse proxy / TLS | **Caddy** | Auto-TLS with Let's Encrypt out of the box. Zero-config cert renewal. One Caddyfile, no certbot cron, no nginx reload dance. Adds one container to compose. |
| Auth library | **Auth.js v5** (next-auth@5) in Next.js | Discord provider built in. Handles OAuth flow, CSRF, cookie signing, JWT/session. Eliminates ovp-api's OAuth routes entirely for the portal use case. |
| Session strategy | **JWT** (Auth.js default, no DB needed) | The frontend doesn't need server-side session revocation today. JWTs are stateless, zero-infra. Switch to database sessions later if revocation becomes a requirement. |
| Dev whitelist | **Next.js middleware** + env var | Check `session.user.id` against `ALLOWED_DISCORD_IDS` on every request in dev. Reject with 403 before hitting any page. |

### Why not keep ovp-api for OAuth?

The ovp-api already has Discord OAuth scaffolded, but it uses an in-memory
session store and was designed as a BFF. Now that the frontend *is* the BFF
(Next.js API routes proxy to data-api with shared-secret auth), adding another
hop through ovp-api for user auth creates:

- An extra network hop and failure point.
- Two session stores to reason about (ovp-api's in-memory store + whatever
  the frontend uses).
- Cookie domain complexity (the cookie must be set on the domain the browser
  talks to, which is the frontend's domain, not ovp-api's).

Auth.js in Next.js handles the entire OAuth flow in the same process that
serves the pages. The ovp-api OAuth routes become dead code for the portal
use case. ovp-api remains useful as a public REST API for third-party
integrations, but the portal should own its own auth.

---

## 2. DNS Configuration

### Records to create

| Record | Type | Value | TTL |
|---|---|---|---|
| `sessionhelper.com` | A | `87.99.134.42` (prod VPS) | 300 |
| `app.sessionhelper.com` | A | `87.99.134.42` (prod VPS) | 300 |
| `dev.sessionhelper.com` | A | `178.156.144.147` (dev VPS) | 300 |

Caddy handles TLS for each subdomain independently. No wildcard cert needed.

### Verification

```bash
dig +short app.sessionhelper.com   # should return 87.99.134.42
dig +short dev.sessionhelper.com   # should return 178.156.144.147
```

---

## 3. Caddy Reverse Proxy

### 3a. Caddyfile (dev VPS)

```caddyfile
dev.sessionhelper.com {
    reverse_proxy frontend:3000
    encode gzip

    header {
        Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Referrer-Policy "strict-origin-when-cross-origin"
        Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' https://cdn.discordapp.com data:; connect-src 'self'; frame-ancestors 'none'"
    }
}
```

### 3b. Caddyfile (prod VPS)

```caddyfile
app.sessionhelper.com {
    reverse_proxy frontend:3000
    encode gzip

    header {
        Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Referrer-Policy "strict-origin-when-cross-origin"
        Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' https://cdn.discordapp.com data:; connect-src 'self'; frame-ancestors 'none'"
    }
}
```

### 3c. Docker Compose additions

Add to the existing `docker-compose.yml` on each VPS:

```yaml
services:
  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"   # HTTP/3
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data       # TLS certs persist here
      - caddy_config:/config
    depends_on:
      - frontend

  frontend:
    build:
      context: ../ttrpg-collector-frontend
      dockerfile: Dockerfile
    restart: unless-stopped
    env_file: .env.frontend
    expose:
      - "3000"
    depends_on:
      - postgres

volumes:
  caddy_data:
  caddy_config:
```

The frontend container does NOT expose ports to the host. Only Caddy binds
80/443. All traffic flows: `Internet -> Caddy (TLS termination) -> frontend:3000`.

### 3d. Frontend Dockerfile

Create `ttrpg-collector-frontend/Dockerfile`:

```dockerfile
FROM node:22-alpine AS base

FROM base AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts

FROM base AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npm run build

FROM base AS runner
WORKDIR /app
ENV NODE_ENV=production
RUN addgroup --system --gid 1001 nodejs && \
    adduser --system --uid 1001 nextjs
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public
USER nextjs
EXPOSE 3000
ENV PORT=3000
CMD ["node", "server.js"]
```

Requires `output: "standalone"` in `next.config.ts` (see section 4).

---

## 4. Auth.js / Next.js Auth Configuration

### 4a. Install dependencies

```bash
cd ttrpg-collector-frontend
npm install next-auth@5
```

### 4b. `next.config.ts` changes

```ts
import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: "standalone",  // Required for Docker deployment
};

export default nextConfig;
```

### 4c. Create `src/lib/auth.ts`

This is the central Auth.js configuration file.

```ts
import NextAuth from "next-auth";
import Discord from "next-auth/providers/discord";

export const { handlers, auth, signIn, signOut } = NextAuth({
  providers: [
    Discord({
      clientId: process.env.AUTH_DISCORD_ID!,
      clientSecret: process.env.AUTH_DISCORD_SECRET!,
      authorization: {
        params: { scope: "identify" },
      },
    }),
  ],

  callbacks: {
    // Persist Discord user ID and username into the JWT.
    jwt({ token, profile }) {
      if (profile) {
        token.discordId = profile.id;
        token.username = profile.username;
        token.avatar = profile.avatar;
      }
      return token;
    },

    // Expose Discord fields to the client-side session.
    session({ session, token }) {
      session.user.discordId = token.discordId as string;
      session.user.username = token.username as string;
      session.user.avatar = token.avatar as string | null;
      return session;
    },
  },

  pages: {
    signIn: "/auth/signin",   // Custom sign-in page (optional)
    error: "/auth/error",
  },

  // Trust the reverse proxy's X-Forwarded-* headers.
  trustHost: true,
});
```

### 4d. Create `src/app/api/auth/[...nextauth]/route.ts`

```ts
import { handlers } from "@/lib/auth";

export const { GET, POST } = handlers;
```

### 4e. Extend session types — `src/types/next-auth.d.ts`

```ts
import "next-auth";

declare module "next-auth" {
  interface Session {
    user: {
      discordId: string;
      username: string;
      avatar: string | null;
    } & DefaultSession["user"];
  }
}

declare module "next-auth/jwt" {
  interface JWT {
    discordId?: string;
    username?: string;
    avatar?: string | null;
  }
}
```

### 4f. Update the `useAuth` hook

Replace the existing `src/hooks/use-auth.ts` that calls `api.auth.me()` with
Auth.js's `useSession()`:

```ts
"use client";

import { useSession } from "next-auth/react";

export function useAuth() {
  const { data: session, status } = useSession();

  return {
    user: session?.user
      ? {
          discord_id: session.user.discordId,
          username: session.user.username,
          avatar: session.user.avatar,
        }
      : null,
    loading: status === "loading",
    error: status === "unauthenticated" ? "Not signed in" : null,
  };
}
```

### 4g. Wrap the app in `SessionProvider`

In `src/app/layout.tsx`, add the Auth.js session provider:

```tsx
import { SessionProvider } from "next-auth/react";

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <SessionProvider>
          {children}
        </SessionProvider>
      </body>
    </html>
  );
}
```

### 4h. Discord Developer Portal setup

1. Go to https://discord.com/developers/applications
2. Create application (or reuse existing) for each environment:
   - **Dev app**: redirect URI `https://dev.sessionhelper.com/api/auth/callback/discord`
   - **Prod app**: redirect URI `https://app.sessionhelper.com/api/auth/callback/discord`
3. Copy Client ID and Client Secret into each environment's `.env`.

---

## 5. Dev Whitelist Implementation

### 5a. Environment variable

In the dev environment's `.env.frontend`:

```bash
# Comma-separated Discord user IDs allowed on dev
ALLOWED_DISCORD_IDS=123456789012345678,234567890123456789
```

Leave this variable **unset** in production (no whitelist = open to all
authenticated users).

### 5b. Next.js middleware — `src/middleware.ts`

```ts
import { auth } from "@/lib/auth";
import { NextResponse } from "next/server";

const ALLOWED_IDS = process.env.ALLOWED_DISCORD_IDS
  ? new Set(process.env.ALLOWED_DISCORD_IDS.split(",").map((s) => s.trim()))
  : null;

export default auth((req) => {
  // Public paths that don't require auth.
  const { pathname } = req.nextUrl;
  if (
    pathname.startsWith("/api/auth") ||
    pathname.startsWith("/auth/") ||
    pathname === "/favicon.ico"
  ) {
    return NextResponse.next();
  }

  // Not authenticated — redirect to sign-in.
  if (!req.auth) {
    return NextResponse.redirect(new URL("/auth/signin", req.url));
  }

  // Dev whitelist: reject users not in the allow-list.
  if (ALLOWED_IDS && !ALLOWED_IDS.has(req.auth.user.discordId)) {
    return new NextResponse("Access denied: your Discord account is not on the dev whitelist.", {
      status: 403,
    });
  }

  return NextResponse.next();
});

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};
```

This runs on every request (except static assets). On prod where
`ALLOWED_DISCORD_IDS` is unset, `ALLOWED_IDS` is `null` and the check is
skipped entirely.

---

## 6. Environment Configuration

### 6a. Architecture: separate VPS, separate stacks

| | Dev | Prod |
|---|---|---|
| VPS | `178.156.144.147` | `87.99.134.42` |
| Domain | `dev.sessionhelper.com` | `app.sessionhelper.com` |
| Compose stack | Independent copy | Independent copy |
| Database | Separate postgres instance | Separate postgres instance |
| Shared secret | Different value | Different value |
| Discord app | Separate OAuth app | Separate OAuth app |
| Auth secret | Different value | Different value |

Same compose file, different `.env` files per VPS. No shared state between
environments. This avoids dev accidents corrupting prod data.

### 6b. `.env.frontend` template

```bash
# --- Auth.js ---
AUTH_SECRET=          # openssl rand -base64 32
AUTH_DISCORD_ID=      # Discord OAuth client ID
AUTH_DISCORD_SECRET=  # Discord OAuth client secret

# --- Data API (server-side only, never exposed to browser) ---
DATA_API_URL=http://data-api:8001
DATA_API_SHARED_SECRET=

# --- Dev whitelist (dev only, omit in prod) ---
# ALLOWED_DISCORD_IDS=123456789,234567890

# --- Public vars ---
NEXTAUTH_URL=https://dev.sessionhelper.com   # or https://app.sessionhelper.com
```

Generate `AUTH_SECRET` with:
```bash
openssl rand -base64 32
```

---

## 7. Step-by-Step Deployment Guide

### Phase 1: DNS (do first, propagation takes time)

1. Add A records per section 2.
2. Verify with `dig +short dev.sessionhelper.com` and `dig +short app.sessionhelper.com`.

### Phase 2: Discord apps

1. Create two Discord OAuth applications (dev and prod).
2. Set redirect URIs:
   - Dev: `https://dev.sessionhelper.com/api/auth/callback/discord`
   - Prod: `https://app.sessionhelper.com/api/auth/callback/discord`
3. Copy Client ID and Secret into `pass` store.

### Phase 3: Frontend auth code

1. `npm install next-auth@5` in `ttrpg-collector-frontend`.
2. Create `src/lib/auth.ts` (section 4c).
3. Create `src/app/api/auth/[...nextauth]/route.ts` (section 4d).
4. Create `src/types/next-auth.d.ts` (section 4e).
5. Update `useAuth` hook (section 4f).
6. Add `SessionProvider` to layout (section 4g).
7. Create `src/middleware.ts` (section 5b).
8. Update `next.config.ts` to add `output: "standalone"` (section 4b).
9. Remove ovp-api auth references from `api-client.ts` (the `/api/v1/auth/*`
   calls are replaced by Auth.js).
10. Test locally: `AUTH_DISCORD_ID=... AUTH_DISCORD_SECRET=... AUTH_SECRET=... npm run dev`.

### Phase 4: Docker (dev VPS first)

1. Create `ttrpg-collector-frontend/Dockerfile` (section 3d).
2. Add `caddy` and `frontend` services to `docker-compose.yml` (section 3c).
3. Create `Caddyfile` for dev (section 3a).
4. Create `.env.frontend` with dev values (section 6b).
5. SSH to dev VPS:
   ```bash
   docker compose build frontend
   docker compose up -d caddy frontend
   docker compose logs -f caddy   # watch for cert acquisition
   ```
6. Verify: open `https://dev.sessionhelper.com` in browser.
7. Verify: Discord sign-in flow completes.
8. Verify: non-whitelisted user gets 403.

### Phase 5: Prod VPS

1. Repeat phase 4 with prod values.
2. Use `app.sessionhelper.com` Caddyfile (section 3b).
3. Omit `ALLOWED_DISCORD_IDS` from `.env.frontend`.
4. Smoke test the full flow.

---

## 8. Security Checklist

### Cookies & Sessions
- [x] Auth.js sets `HttpOnly`, `Secure`, `SameSite=Lax` by default on its session cookie.
- [ ] Verify `AUTH_SECRET` is a strong random value (32+ bytes), different per environment.
- [ ] Verify `AUTH_SECRET` is in `pass`, not committed to any repo.

### TLS
- [ ] Caddy acquires valid Let's Encrypt certs for both subdomains.
- [ ] HSTS header present with long max-age (Caddyfile includes it).
- [ ] HTTP/2 and HTTP/3 working (Caddy enables both by default).

### Headers
- [ ] `X-Content-Type-Options: nosniff` present.
- [ ] `X-Frame-Options: DENY` present (no embedding allowed).
- [ ] `Content-Security-Policy` restricts sources to self + Discord CDN.
- [ ] `Referrer-Policy: strict-origin-when-cross-origin` present.

### Network Isolation
- [ ] `frontend` container uses `expose` (not `ports`) — only Caddy can reach it.
- [ ] `data-api`, `postgres`, `worker`, `collector` containers have NO published ports on the host.
- [ ] All internal services communicate over the Docker Compose network only.

### Secrets
- [ ] `.env.frontend` is in `.gitignore`.
- [ ] `DATA_API_SHARED_SECRET` is different between dev and prod.
- [ ] Discord OAuth secrets are different between dev and prod.
- [ ] No secrets in Caddyfile or docker-compose.yml (they're in `.env` files).

### Rate Limiting
- [ ] Consider adding `caddy-ratelimit` plugin if abuse becomes an issue.
  For now, Discord OAuth is a natural rate-gate (no anonymous access).

### Dev Whitelist
- [ ] `ALLOWED_DISCORD_IDS` is set on dev VPS.
- [ ] `ALLOWED_DISCORD_IDS` is NOT set on prod VPS.
- [ ] A non-whitelisted Discord user gets 403, not a redirect loop.

### CORS
- [ ] Not needed — the browser talks to the same origin (Next.js serves
  both pages and API routes). The data-api CORS config is irrelevant because
  the browser never contacts it directly.

---

## 9. Architecture Diagram

```
                         Internet
                            |
                     ┌──────┴──────┐
                     │    Caddy    │  :80 / :443
                     │  (auto-TLS) │
                     └──────┬──────┘
                            │
                     ┌──────┴──────┐
                     │  Next.js    │  :3000 (internal)
                     │  Frontend   │
                     │             │
                     │  Auth.js    │  ← Discord OAuth
                     │  API routes │  ← BFF to data-api
                     │  Middleware  │  ← dev whitelist
                     └──────┬──────┘
                            │ shared-secret auth
                     ┌──────┴──────┐
                     │  data-api   │  :8001 (internal)
                     └──────┬──────┘
                            │
                     ┌──────┴──────┐
                     │  postgres   │  :5432 (internal)
                     └─────────────┘
```

Browser never talks to data-api. Auth.js handles user identity.
Next.js API routes handle data-api communication with shared-secret auth.

---

## 10. Migration Notes

### What changes in existing code

1. **`src/lib/api-client.ts`**: Remove `auth.me()`, `auth.discordCallback()`,
   `auth.logout()`. These are replaced by Auth.js's built-in routes
   (`/api/auth/session`, `/api/auth/signin`, `/api/auth/signout`).

2. **`src/hooks/use-auth.ts`**: Rewrite to use `useSession()` (section 4f).

3. **`src/lib/data-api.ts`**: No changes. Server-side shared-secret auth
   to data-api continues unchanged.

4. **`src/app/api/events/route.ts`**: No changes. SSE bridge continues to
   use shared-secret auth.

5. **`next.config.ts`**: Add `output: "standalone"`.

6. **ovp-api**: Its Discord OAuth routes become unused by the portal. Leave
   them for potential third-party API use, or remove if not needed.

### What stays the same

- The BFF pattern (browser -> Next.js API routes -> data-api) is unchanged.
- Shared-secret auth between frontend and data-api is unchanged.
- All existing API routes (`/api/sessions/*`, `/api/events`, `/api/health`)
  are unchanged.
- The data-api, worker, collector, and feeder services are unchanged.

---

## Open Questions

1. **Custom sign-in page**: Do we want a branded sign-in page at `/auth/signin`
   or just redirect straight to Discord? Auth.js supports both.

2. **Session duration**: Auth.js defaults to 30-day sessions. Adjust?

3. **Database sessions vs JWT**: JWTs are fine for now. If we need server-side
   session revocation (e.g., ban a user mid-session), we'd switch to database
   sessions backed by the existing postgres. This is a one-line change in
   Auth.js config.

4. **ovp-api deprecation**: With auth in Next.js and data access via BFF
   routes, does ovp-api still serve a purpose? It could become the public
   REST API for non-browser clients (mobile, third-party integrations).

5. **Rate limiting**: Caddy has a rate-limit plugin, but it requires building
   a custom Caddy image. Worth it now, or wait until there's actual abuse?
