# Legal — incorporation and banking journey

This directory holds abstract notes on the legal and financial setup for a small, minimalist, open-source-adjacent voice dataset project. **No specific filing numbers, EIN, account details, or personal info lives here** — those are tracked in a local-only private companion repo on the maintainer's machine. This doc is for anyone traveling the same path who wants to know the *shape* of the decisions.

## Why incorporate at all

A Discord bot that records user voice, even with consent, touches real privacy law. A single-member LLC gives you:

- **Liability shield** between the project and your personal finances if a user ever claims harm.
- **A legal entity** that can sign a privacy policy and a data processing agreement, own a domain, hold a bank account, and receive donations without commingling with your personal income.
- **A clean tax story**: a single-member LLC is a disregarded entity by default in the US, so you still file on Schedule C, but all the project's money flows through business accounts. No passthrough bookkeeping until the project grows enough to matter.

If the project never makes a dollar, the LLC is mostly paperwork and a small annual fee. If it does, you're already set up.

## Why the state we chose

We incorporated in **New Mexico**. The decision came down to four factors:

| Factor | NM | Delaware | Wyoming | Your home state |
|---|---|---|---|---|
| Filing cost | **$50 one-time** | $90 + $300/yr franchise tax | $100 + $60/yr | Varies ($100–$800+) |
| Annual report | **None** | Required, ~$300 | Required, ~$60 | Usually yes |
| Anonymity on public filing | **High** (member not listed) | Medium | High | Usually low |
| Registered agent required | Yes (~$35–$125/yr) | Yes | Yes | Yes |

New Mexico's combination of "$50 one-time, no annual report, member identity not required on public filing" was the cheapest path to a real LLC that doesn't leak your home address into Google every year. The tradeoff is NM doesn't have the pristine corporate case law of Delaware, but for a consumer-facing project that isn't raising venture capital, that doesn't matter.

If the project ever raises money or operates at scale, you can always domesticate elsewhere later.

## Registered agent

Every US state requires a registered agent — a physical address in the state that can receive legal service. **Do not use your home address.** A registered agent service charges $35–$150/year and gives you a commercial forwarding address.

We picked a local NM-specific service over the big national ones because:

- Lower annual cost (~$35 vs ~$125 for the nationals).
- They have a web portal that pushes any received mail to your email within a day or two, which is what you actually care about.
- Supporting a small business doing a straightforward service is on-brand for the project.

## Filing workflow

For someone following the same path, the typical order is:

1. **Pick a business name.** Search the state's business entity database to make sure it's available, then reserve it or just file directly.
2. **Pick a registered agent** and get their service address + phone in hand before filing.
3. **File Articles of Organization** with the Secretary of State (NM does this online at enterprise.sos.nm.gov). Cost: $50. Turnaround: same day to 2 business days.
4. **Wait for approval**, then save the stamped filing PDF.
5. **Apply for an EIN** at the IRS website (free, instant, online). Single-member LLC → disregarded entity → you as the responsible party.
6. **Open a business bank account.** Most online business banks will accept the Articles + EIN and have you running in 24–48 hours. Pick one with no monthly fee at low balances and integrated ACH/invoicing if you ever plan to take donations.
7. **Connect payment processors** (Stripe, Ko-fi, GitHub Sponsors) using the business EIN and account.

## Separating personal and business

From day one:

- **Use a business email** that forwards to your personal inbox, not the other way around. This lets you migrate later without changing addresses on every account.
- **All project expenses go through the business account.** Domain, VPS, registered agent, even small API bills. Keeps Schedule C math trivial at tax time.
- **Secrets live in `pass`** (or equivalent) under a business namespace, not mixed with personal credentials.
- **Sign things as "<Company> LLC"**, never as yourself personally, on any legal or contractual document that touches the project.

## Things we explicitly decided NOT to do (yet)

- **S-corp election.** Makes sense once the project pays you more than ~$40k/yr; below that the SE tax savings don't justify the payroll complexity.
- **Separate trademark filing.** Expensive ($250–$750 per class), slow (months), and not valuable until you have brand equity worth defending.
- **Privacy policy from a lawyer.** For the first version, a plain-English one based on the consent the bot actually collects is enough. Lawyer-drafted policies are worth it once you have real user data and real obligations.
- **Insurance (E&O, general liability).** Defer until there's money or user exposure that could attract a lawsuit.

## What lives where

| Concern | Location |
|---|---|
| Specific filing number, EIN, registered agent address, bank account details | Private companion repo (local-only) |
| Abstract "why we chose X, how we did it" — this document | This repo, published |
| Credential storage | `pass` on the maintainer's machine; no values ever committed anywhere |
