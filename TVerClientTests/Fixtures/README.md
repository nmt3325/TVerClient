# Fixtures

Synthetic payloads that mirror the **structure** of the real TVer responses.
All values are placeholders: no real IDs, titles, tokens or image paths, because
this repository is public.

- Committed fixtures pin the shapes `TVerAPIClient` must keep decoding.
- `FixtureMutationTests` mutates every fixture six ways and asserts the client
  degrades instead of crashing or returning nothing.
- `scripts/capture-fixtures.sh` writes raw upstream captures to `Captured/`,
  which is gitignored. Copy the *structure* of a capture into a fixture by hand;
  never commit the capture itself.
