---
name: lorvex-planning
description: Use when asked to review, plan, create or change tasks, lists, calendar events or habits in the user-connected Lorvex app.
---

# Lorvex planning

Use the connected Lorvex tools to inspect actual account data before planning or changing it. Never invent task contents, successful writes, synchronization results, or account eligibility.

## Lorvex Cloud

Prefer the `lorvex-cloud` connection at `/cloud/mcp` when available and authenticated. It uses normal Lorvex account sign-in and OAuth consent. It does not use an eight-character iPad pairing code.

Cloud tools operate directly on the central account. With the appropriate OAuth permission and a user's requested action, routine task creation, editing, completion and scheduling do not require the iPad to be open or an additional approval on the iPad. Always honor ChatGPT's own approval requirements and any required confirmation for an exceptional or destructive operation.

Read only the records needed for the request, use their actual identifiers, and inspect the returned result before reporting success. A timeout is an unknown outcome: reread the affected data before retrying a write. Do not repeat a write through another connection or create a second copy merely because a response was lost.

The iPad keeps a local offline database and synchronizes with the same Cloud account when it reconnects. A successful Cloud write is evidence of server persistence, not evidence that an offline iPad has already received it. Verify device synchronization separately when requested.

## Existing iPad bridge

The `lorvex-remote` connection at `/mcp` is retained during migration. It operates against the previously paired iPad and still requires its foreground connection and local write approval. Use it only when the user explicitly chooses that device connection or Cloud is not yet connected. Make that context clear before making changes. Do not assume the legacy device database and a Cloud account are already the same data set, and never silently send the same change to both.

## Account boundaries

Use only the authenticated account and granted scopes. Do not copy credentials between Cloud and the iPad bridge, extract cookies, expose tokens, or claim access to another account. A sign-in requirement must be completed through the provided OAuth flow.

This MCP connection is separate from Sign in with ChatGPT inside Lorvex. It does not grant the embedded AI assistant use of a ChatGPT plan.
