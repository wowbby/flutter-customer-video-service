## 0.4.0

* Move the bundled WebView, H5 protocol and document bindings to the Demo. Hosts connect their existing business actions directly to VideoServiceController and read typed session state.

## 0.3.0

* Add mixed-host lifecycle and window handoff, trusted per-document request context, media readiness, camera and video options, scoped control recovery and typed diagnostics.

## 0.2.0

* Add immutable call request/context to credentials and token providers (Dart API migration required).
* Return original-session accepted/cancelled start results; separate host business state from RTC connection and media state.
* Provide guarded business signals, confirmed end summaries, monotonic accepted duration and a retained latest summary.
* Normalize errors/recovery and distinguish confirmed release warnings from blocked, unconfirmed cleanup.
* Preserve H5 v1 actions and existing fields; add a safe start result and lifecycle snapshot fields without business metadata or credentials.

See README for migration and current single-engine/platform boundaries.
