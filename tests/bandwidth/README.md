# URLSessionAVIOSource bandwidth tests

Self-contained Swift command-line tests that reproduce the production
`URLSessionAVIOSource` logic without FFmpeg or the device, so you can
iterate on throughput hypotheses from the Mac.

## Files

- `bw_test.swift` — baseline comparisons: plain `URLSession.dataTask`,
  `URLSessionDataDelegate`, our AVIO pattern, and the pattern with
  simulated FFmpeg processing latency.
- `mock_plex_server.swift` — local HTTP server that models Plex's
  observed quirks: short responses, rate limits, artificial
  first-byte delay. Deterministic body (`byte[pos] == pos & 0xFF`)
  so the client can verify correctness after a seek.
- `avio_seek_test.swift` — reproduces the seek/drain/auto-restart
  behavior from `URLSessionAVIOSource.swift`. Points at
  `mock_plex_server.swift` by default. Scenarios: `healthy`,
  `truncating`, `seeky`, `seeky-noop`.
- `run_scenarios.sh` — orchestrates the above into a sweep.

## Quick runs

```bash
# Baseline: what can URLSession do against a healthy localhost server?
python3 -m http.server 18420 &
BW_TEST_URL=http://127.0.0.1:18420/testfile.bin swift bw_test.swift

# Full scenario sweep with the mock server
./run_scenarios.sh

# Against the real Plex static endpoint (needs LAN access to 192.168.1.140)
AVIO_TEST_URL="http://192.168.1.140:32400/web/js/main-...-plex-4.156.0-...js" \
AVIO_TEST_BYTES=3499000 AVIO_TEST_VERIFY=0 \
swift avio_seek_test.swift healthy
```

## Findings so far (2026-04-08)

- Our AVIO pattern is NOT a bottleneck. Against localhost it hits
  7+ Gbps. Against real Plex static endpoint on LAN it hits ~500 Mbps.
- `auto-restart on unexpected EOF` handles short responses with zero
  throughput impact (matches healthy rate).
- `forward drain beyond the pending buffer` is a pessimization: it
  pulls multiples of the skipped bytes from the network. Only drain
  when `pendingChunkBytes >= delta`; otherwise restart.
- The observed ~7 Mbps cap on the Apple TV does NOT reproduce on Mac
  against the same server. Likely culprits: WiFi link quality,
  tvOS-specific URLSession behavior, or authenticated media endpoint
  serving characteristics.
