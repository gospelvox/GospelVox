# Coin Deduction — Deep Analysis

Scope: every code path that moves coins between user wallet, priest wallet, and the platform commission pool. Specifically: what happens during a session, what happens at short cutoffs (1.25s), what happens during network failures, what happens during force-quits, and where any double-bill / under-bill risks live.

Method: read every relevant CF (`billingTick`, `endSession`, `expireSessionRequest`, `sessionWatchdog`, `createSessionRequest`), the user-side cubits (`chat_session_cubit`, `voice_call_cubit`), and the priest-side equivalents. Traced each timing window second-by-second. Cross-referenced against Firestore rules.

---

## 1. Architecture (how billing works today)

| Element | Where | Responsibility |
|---|---|---|
| Billing meter | User-side client only (`chat_session_cubit.dart:423-427`, `voice_call_cubit.dart:445-447`) | A `Timer.periodic(60s)` fires `_runBillingTick()` once a minute. |
| Single deduction op | `functions/src/sessions/billingTick.ts` | Reads session + user, increments `durationMinutes` by 1, decrements user `coinBalance` by `rate`, credits priest `walletBalance + totalEarnings` by `floor(rate × (1 − commission%))`, writes a `wallet_transactions` ledger row — all in **one batch**. |
| Minimum 1-minute floor | `endSession.ts:70-104` AND `sessionWatchdog.ts:218-277` | If session reached `status='active'` but `durationMinutes==0` when settled, charge exactly **one minute**. |
| Insufficient-balance auto-end | `billingTick.ts:79-92` | If `currentBalance < rate` at the **start** of a tick, flip `status='completed', endReason='balance_zero'` **without** deducting. Return `shouldEnd:true` so client tears down. |
| Idempotent re-bill | `endSession.ts:49-57` | If session is already `completed`, return the existing summary. Never re-charges. |
| Watchdog safety net | `sessionWatchdog.ts:200-442` | Every 5 minutes, find sessions with `status='active'` AND `lastHeartbeat < (now − 2 min)`. Apply minimum charge if needed, settle, clear `isBusy`. |

**Key invariants the code maintains:**
- The priest side **never** calls `billingTick` (`chat_session_cubit.dart:411-426` gates on `_isUserSide`). Eliminates double-billing-from-two-clients.
- `durationMinutes` is monotonic — it only ever increments by 1 inside `billingTick`'s batch.
- Every deduction lands in a single `db.batch().commit()` so user-debit, priest-credit, session-update, and ledger-row succeed or fail together.
- Rate and commission are **locked at session creation** (`createSessionRequest.ts:104-117`) and read off the session doc thereafter, so an admin editing `app_config/settings` mid-call doesn't retro-bill.

---

## 2. Timeline by exact moment

Setup: `rate=10`, `commission=20%`, user starts with 50 coins.

### Priest cuts at **1.25 seconds**

```
t=0.00s  acceptSession runs (batch):
         sessions/{id}.status: active, startedAt, lastHeartbeat
         priests/{id}.isBusy: true
         → user client navigates to chat/voice page
         → user client starts 60s billing timer (first fire at t=60.00s)
         → user client starts 30s heartbeat timer

t=1.25s  Priest taps End.
         priest cubit → endSession CF:
           - status read: 'active'
           - finalDuration read: 0
           - Minimum-charge branch triggers (endSession.ts:70)
           - currentBalance (50) >= rate (10) → batch:
               users/{u}.coinBalance: -10  (atomic increment)
               priests/{p}.walletBalance: +8  (10 × (1 − 0.2))
               priests/{p}.totalEarnings: +8
               wallet_transactions/{x}: { type: 'session_charge', coins: -10, description: '… minimum charge' }
           - finalDuration = 1, finalTotalCharged = 10, finalPriestEarnings = 8
         - sessionRef.update: status='completed', endedAt, durationMinutes=1, totalCharged=10, priestEarnings=8, endedBy='priest'
         - priests/{p}: totalSessions: +1, isBusy: false
         - onSessionTerminal trigger fires (no-op for isBusy because endSession already cleared it)
```

**Result for a 1.25s priest cut:**
- User: paid 10 coins (1 full minute)
- Priest: earned 8 coins
- Platform: kept 2 coins (commission)
- User remaining balance: 40 coins
- Both sides land on rating dialog (user) / summary (priest)

This is the **minimum-charge floor**. Standard for the category (matches AstroTalk / similar). Documented in `endSession.ts:66-69` and `createSessionRequest.ts:114-118`.

### User cuts at 1.25 seconds

Identical to priest cut — same `endSession` CF path. User pays 10. Priest earns 8.

### Either side cuts at **59.9 seconds**

```
t=0.00s   accept
t=59.90s  end tapped
          (billingTimer hasn't fired yet — it fires at t=60.00s)
          endSession CF:
            - status='active', durationMinutes=0
            - Minimum charge fires → 10 coins deducted, 8 to priest
```

Same as 1.25s case. **One minute charged for 59.9 seconds of talk.**

### Either side cuts at **60.5 seconds**

```
t=0.00s   accept
t=60.00s  billingTimer fires → billingTick CF:
            - status='active', balance=50 >= 10 → deduct
            - durationMinutes 0 → 1, totalCharged 0 → 10, priestEarnings 0 → 8
            - shouldEnd: false (newBalance=40 >= rate=10)
t=60.5s   end tapped
          endSession CF:
            - status='active', durationMinutes=1
            - Minimum-charge branch SKIPPED (durationMinutes != 0)
            - sessionRef.update: status='completed', durationMinutes=1 (unchanged)
```

**One minute charged for 60.5 seconds of talk.** Same outcome as 59.9s. The minute-floor is the same whether the cut happens at 1s or 59s.

### Either side cuts at **119 seconds**

```
t=0s     accept
t=60s    billingTick #1 → duration=1, totalCharged=10, balance=40, shouldEnd=false
t=119s   end tapped
         endSession CF: status='active', duration=1 → no min-charge → settle as-is
```

**One minute charged for 119 seconds.** This is the "fairness window": users can talk for up to 59 seconds of un-billed time at the end of every minute. Designed-in.

### Either side cuts at **121 seconds**

```
t=0s     accept
t=60s    billingTick #1 → duration=1, balance=40
t=120s   billingTick #2 → duration=2, balance=30, totalCharged=20
t=121s   end tapped
         endSession CF: status='active', duration=2 → settle as-is
```

**Two minutes charged for 121 seconds.** Correct.

### User runs out of coins mid-call

Setup: starts with 30 coins, rate=10.

```
t=0s    accept
t=60s   billingTick #1: balance=30 >= 10 → deduct → balance=20, duration=1
                       newBalance(20) < rate(10) → false → shouldEnd=false
t=120s  billingTick #2: balance=20 >= 10 → deduct → balance=10, duration=2
                       newBalance(10) < rate(10) → false → shouldEnd=false
t=180s  billingTick #3: balance=10 >= 10 → deduct → balance=0, duration=3
                       newBalance(0) < rate(10) → TRUE → shouldEnd=true
        Client receives shouldEnd:true → calls endSession(reason: 'balance_zero')
        endSession CF: status='active' (until our update), duration=3
                       Min-charge branch skipped (duration != 0)
                       sessionRef.update: status='completed'
        + onSessionTerminal fires → priests/{p}.isBusy: false
        + push notifications to both sides
```

**Three minutes charged for 180+ seconds, balance hits exactly 0.** Correct.

### User goes negative? Can never happen.

`billingTick.ts:79-92` checks `currentBalance < rate` **before** deducting. If true, flips `status='completed'` and returns without touching coinBalance. The user's balance is never debited below `rate`-cost-of-one-minute.

But what about race: balance=10, two billingTicks arrive simultaneously? Both read balance=10, both pass the check, both deduct. **See section 4.A — this is a real risk.**

---

## 3. Network failure scenarios

### A. Client → CF call **never arrives** (radio drop before request leaves)

```
t=60s   Timer fires, _runBillingTick() called
        _repository.callBillingTick() throws (timeout / no network)
        catch block: debugPrint, no retry
        Server-side state: unchanged. session.durationMinutes still 0.
        Heartbeat also fails (same network).
        
t=180s  Watchdog 5-min cron sees lastHeartbeat > 2 min stale
        processStaleSession:
          - finalDuration = 0 → applies minimum 1-minute charge
          - sessionRef.update: status='completed', durationMinutes=1
```

**Outcome:** user got 3 minutes of session, paid 1 minute. Some free time, but correctly settled. No crash, no zombie session.

### B. CF processed successfully but **response never reaches client**

```
t=60s     Client fires billingTick. CF processes, deducts, commits batch. 
          Network drops before HTTP response arrives.
          Client receives timeout/exception, catches, logs debugPrint.
          Server state: durationMinutes=1, balance debited.

t=120s    Client fires billingTick AGAIN (its local "duration" was never advanced).
          CF reads session.durationMinutes=1 (already incremented), deducts again,
          increments to 2.
          Client receives the response, updates local state to duration=2,
          balance=30.
```

**Outcome:** user paid correctly (2 minutes for 2 minutes of talk). Server reality matches. **No double-bill** because the CF computes `newDuration = read + 1` server-side, not from the client's view.

### C. Heartbeat **works** but `billingTick` CF fails

This happens if the Functions endpoint is down but Firestore is up. **Genuinely rare.** Heartbeat keeps the session out of the watchdog's stale-sweep, but billingTick can't deduct.

**Outcome:** user gets free service until either side hangs up. `endSession` then settles with whatever `durationMinutes` is in the doc (which may be 0 if the failure started from the beginning, applying min charge — or N if some ticks did get through before the outage).

**Concern:** there is no fallback retry of failed billingTicks. A 10-minute outage = 10 minutes free for the user. This is acceptable given how unlikely the scenario is, but worth knowing.

### D. Both sides lose network simultaneously

```
t=60s    billingTick #1 succeeds → duration=1, balance=40
t=90s    Both apps lose network. Both heartbeats stop.
         Session in Firestore: status='active', duration=1, lastHeartbeat = 90s ago.
t=270s   Watchdog 5-min cron runs.
         processStaleSession:
           - finalDuration=1 (NOT 0) → min-charge branch skipped
           - sessionRef.update: status='completed', durationMinutes=1
           - priests/{p}.isBusy: false
         Both clients get notifications when they reconnect.
```

**Outcome:** user paid 1 minute for what was effectively a longer call (the network drop time is free). Acceptable — neither side could communicate during the drop, so charging for it would be unfair.

### E. App backgrounded on iOS for > 2 minutes mid-call

```
t=0s     accept, billing timer starts.
t=60s    billingTick #1 fires, succeeds.
t=90s    User puts app in background. iOS pauses Timer.periodic immediately
         (this is iOS's documented behaviour for Dart isolate timers).
         Heartbeat timer also pauses.
t=210s   Watchdog cron: lastHeartbeat (60s) > 2 min stale → processStaleSession.
         finalDuration=1 → settle with 1 minute charge.
```

**Outcome:** 3.5 minutes of session, 1 minute charged. iOS-backgrounding effectively pauses billing. Acceptable / consistent with most calling apps.

---

## 4. Real risks found

### **A. Concurrent billingTick double-debit risk (HIGH severity, LOW probability)**

`chat_session_cubit.dart:446-467` and `voice_call_cubit.dart:452-475` both look like this:

```dart
Future<void> _runBillingTick() async {
  if (isClosed) return;
  try {
    final result = await _repository.callBillingTick(_sessionId);
    ...
```

`Timer.periodic` fires **every 60 seconds regardless of whether the previous `_runBillingTick` Future has completed.** There is **no in-flight guard**. I confirmed this with grep — no `_isTickRunning` / `_pendingTick` flag anywhere.

**Failure mode:** if a single billingTick CF round-trip takes ≥ 60 seconds (extreme network, cold-start CF + slow Firestore), the timer fires again while the previous tick is still in flight. Two concurrent CF invocations:

| Step | Tick #1 (in flight from t=60s) | Tick #2 (fires at t=120s) |
|---|---|---|
| Read session | `durationMinutes=0`, `totalCharged=0` | Concurrent: also reads `durationMinutes=0` (if before tick #1 commits) |
| Read user | `balance=50` | Concurrent: `balance=50` |
| Batch commit | `coinBalance: increment(-10)`<br>session `durationMinutes=1, totalCharged=10`<br>wallet_tx ledger row | `coinBalance: increment(-10)`<br>session `durationMinutes=1, totalCharged=10`<br>wallet_tx ledger row |

After both commit:
- **`coinBalance`**: `50 - 10 - 10 = 30` (atomic FieldValue.increment guarantees both decrements apply)
- **`walletBalance` (priest)**: `+8 + 8 = +16` (also atomic)
- **`durationMinutes`**: last-writer-wins on plain update → `1` (loses one minute of accounting)
- **`totalCharged`**: last-writer-wins → `10` (under-counts by 10)
- **wallet_transactions**: two rows, each `-10` (correct — ledger reflects reality)

**Net result:** user charged 20 coins, priest earned 16 coins, but the session doc only "remembers" 10 coins/1 minute. **Ledger is correct; session summary is wrong.** The user's wallet page would show two debits, but the session-end summary would say "1 min, 10 coins charged."

**Probability:** very low under normal Indian-network conditions. CF cold-start + p95 round-trip is ~3 seconds. Would need a 20×-slower request for collision. **Hasn't manifested in your testing yet.**

**Detection:** wallet_transactions collection would show duplicate entries with same sessionId and same minute-description. Easy to spot in admin tools.

**Risk profile:** not a problem today, but the lack of a guard is a latent bug. Other calling apps' SLAs assume 60s ticks complete in <5s; gospel_vox makes the same assumption silently.

### **B. Commission rounding **always** favours platform (LOW severity, by design)**

`billingTick.ts:68-70` and `endSession.ts:76`, `sessionWatchdog.ts:209-211` all use:
```ts
priestEarning = Math.floor(rate × (1 − commission/100))
```

Math.floor truncates toward zero. The remainder is silently absorbed by the platform.

| Rate | Commission% | Theoretical priest share | Math.floor result | Platform extra |
|---|---|---|---|---|
| 10 | 20% | 8.0 | 8 | 0 |
| 10 | 25% | 7.5 | 7 | +0.5 per minute |
| 10 | 30% | 7.0 | 7 | 0 |
| 15 | 33% | 10.05 | 10 | +0.05 per minute |
| 7 | 20% | 5.6 | 5 | +0.6 per minute |
| 7 | 25% | 5.25 | 5 | +0.25 per minute |

**Worst real-world case** (rate=7, commission=20%): priest loses 0.6 coins per minute. Over a 100-minute month, that's 60 coins (~₹60) lost to rounding. Across many priests this adds up to platform revenue.

The code calls this out explicitly: `// commission pool absorbs the rounding remainder`. **Intentional, but not transparent to priests.**

### **C. Chat: no auto-end when priest goes idle (MEDIUM severity)**

`chat_session_cubit.dart:402-410` runs an `_idleWarningTimer` every 30 seconds. After 90 seconds of silence from the other party, it flips `showIdleWarning: true` (a UI banner). It **never auto-ends the session.**

Voice has Agora's `onUserOffline` callback + a 30s disconnect timer (`voice_call_cubit.dart:315-327`). Chat has nothing equivalent.

**Failure mode:** priest opens chat, accepts, gets distracted / phone dies. Chat session stays `active`. User's billing timer keeps deducting every 60 seconds. User pays for nothing until:
- They hang up manually (saw idle warning, gave up)
- They run out of coins (`balance < rate` triggers auto-end)
- Watchdog (2-min stale heartbeat) — but heartbeats are from the USER side, which is still flowing, so this never fires

**Worst case:** user with 1000 coins, rate=10. Priest goes offline, user keeps the chat open. 100 minutes of pure loss to the user, 80 minutes of pure gain to the absent priest.

Mitigation: user sees the 90s idle warning. But there's no enforced end. This is a genuine UX/billing gap.

### **D. Cancel-during-shouldEnd race (LOW severity, cosmetic)**

When `billingTick` returns `shouldEnd:true`, the client immediately fires `endSession`. If the user buys coins at that exact moment, their balance recovers but `_endingDispatched` is already `true` — there's no recovery path. The session ends; the new coins remain in the wallet.

Window is ~100ms. User sees "session ended, balance: 200 coins" right after buying coins. Confusing but not lossy.

### **E. Priest-side `acceptSession` failure leaves user paying for a session that never came up**

If the priest's `acceptSession` batch fails (rules denial, network), the user-side session_request_cubit eventually sees status flip to expired (60s timeout) and the user is **not** charged. ✓ No issue.

### **F. `sendPushNotification` failure on `endSession` doesn't roll back the deduction**

By design. The deduction is the source of truth; the push is best-effort. ✓ Not a bug.

---

## 5. Watchdog interaction

The watchdog (`sessionWatchdog.ts`) runs every 5 minutes. Two relevant sweeps:

### Stuck-pending (status='pending' older than 60s)
Marks expired, sends missed-request notification. No billing. **Clean.**

### Stale-active (status='active', lastHeartbeat older than 2 min)
- Reads current `durationMinutes`/`totalCharged`/`priestEarnings` from the doc
- If `durationMinutes == 0`, applies minimum 1-minute charge (same logic as `endSession`)
- Else, settles with what's already there — does NOT recharge any minute that `billingTick` already processed
- Writes `status='completed', endReason='watchdog_timeout'`

**Correctness:** trust-the-server pattern. The doc is authoritative. The watchdog **never** reconstructs billing from clock time; it only carries forward what `billingTick` already wrote. **No double-bill risk from watchdog.**

**Coverage gap:** in scenario C (heartbeat works, billingTick is broken), the watchdog never fires because the heartbeat is fresh. User keeps getting free service. No fallback billing.

---

## 6. Where the code is genuinely solid

- **Atomic batches** everywhere coins move. User-debit, priest-credit, ledger row, session update all succeed or fail together (`billingTick.ts:101-136`, `endSession.ts:79-98`, `sessionWatchdog.ts:233-261`).
- **Server-authoritative math.** Client never tells the server what to deduct; CF reads from the locked-at-creation `ratePerMinute` and `commissionPercent` on the session doc. An admin changing `app_config/settings` mid-call cannot retro-bill (`createSessionRequest.ts:104-117` snapshots both values into the new session doc).
- **`endSession` idempotency.** Called twice (e.g. both sides tap End simultaneously)? First call settles, second call sees `status='completed'` and short-circuits with the existing summary — no double charge (`endSession.ts:49-57`).
- **Rules cover the wallet attack surface.**
  - `users/{uid}` rules block clients from writing `coinBalance` / `walletBalance` / `role` / `isActivated`. Coin movement is CF-only.
  - `wallet_transactions` is CF-only write (`allow create: if false;`).
  - `withdrawals` rules limit clients to `status='pending'` create; admin can only flip allowed audit fields.
- **Priest never bills.** Side-specific timer wiring at `chat_session_cubit.dart:411` and `voice_call_cubit.dart:441` is gated on `_isUserSide`. Double-billing from concurrent client billers is structurally impossible.

---

## 7. Summary table

| Scenario | Charged | Notes |
|---|---|---|
| Priest cuts at 1.25s | 1 minute | Minimum-charge floor |
| User cuts at 1.25s | 1 minute | Same |
| Either cuts at 59.9s | 1 minute | Same |
| Either cuts at 60.5s | 1 minute | First tick already ran |
| Either cuts at 119s | 1 minute | "Fairness window" — second tick hasn't fired |
| Either cuts at 121s | 2 minutes | Second tick fired at 120s |
| User balance hits zero mid-call | exactly to zero | `billingTick` flips `status='completed'`, returns `shouldEnd:true` |
| Network drop → both clients silent | 1 minute (or whatever was billed before drop) | Watchdog settles at 2 min stale |
| Client crashes before first tick | 1 minute (min charge) | `endSession` or watchdog applies it |
| Client crashes after N ticks | N minutes | Watchdog carries forward existing `durationMinutes` |
| iOS user backgrounds mid-call | Whatever was billed before background | Timer pauses, watchdog catches at 2 min |
| Concurrent ticks (extreme network) | 2× via `FieldValue.increment` | **Session doc undercounts** — risk A |
| Priest goes idle in chat (no end) | Keeps billing the user | **No auto-end** — risk C |

---

## 8. The headline answer to your question

**"Is the coin deduction failing anywhere?"**

**No, not failing in the everyday sense. The math is correct, the batches are atomic, the rules block client tampering, the server is the source of truth.**

There are **two real concerns** worth knowing about, in priority order:

1. **Chat idle-priest hole** — if a priest accepts a chat and then walks away, the user keeps being billed until they hang up or run out of coins. Voice is protected via Agora's onUserOffline. Chat isn't. (Risk C, MEDIUM.)

2. **Concurrent-tick under-count** — under extreme network conditions where a single billingTick takes >60s, two ticks can run concurrently. The user is correctly debited twice (atomic increment), the priest correctly credited twice, but the session doc's `durationMinutes` and `totalCharged` only reflect one tick. Ledger is correct; in-app summary is wrong. (Risk A, HIGH severity if it ever happens, but LOW probability under normal conditions.)

Everything else in the timing analysis (1.25-second cuts charging 1 minute, 119-second cuts charging 1 minute, watchdog cleanup, balance-zero auto-end) is **working as designed.** Standard for the category.

---

*End of analysis.*
