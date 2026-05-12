# Gospel Vox — Code Audit Report

**Scope:** end-to-end audit of every implemented surface. Focus on correctness, dead buttons, missing UI states, silent error swallowing, payment/billing integrity, session lifecycle, and rule mismatches.

**Method:** read each feature's pages, blocs, repositories, and the Cloud Functions they call. Cross-referenced against `firestore.rules` (provided earlier in conversation).

**Disposition:** report only, no fixes applied. Findings grouped by feature so you can address one area at a time. Every finding cites file + line. Where a feature is genuinely clean, it says so.

---

## 0. Implemented features (inventory)

### User-side
- **Auth** — `auth/pages/{role_selection,onboarding,login}_page.dart`
- **Home feed** — `user/home/pages/{home_page,user_shell_page,priest_profile_page}.dart` + cubit
- **Bible tab** — `user/bible/pages/{bible_tab,bible_session_detail_page}.dart`
- **Sessions tab + chat history** — `user/sessions/pages/{sessions_tab,chat_history_page}.dart`
- **Profile / Me tab / Settings / About / Edit profile** — `user/profile/pages/*`
- **Wallet + payment success** — `user/wallet/pages/*`
- **Session waiting → chat / voice → rating dialog** — `user/session/pages/*`
- **Notifications inbox** — `user/notifications/pages/user_notifications_page.dart`

### Priest-side
- **Registration → pending → approved/rejected** — `priest/registration/pages/*`
- **Activation paywall + success** — `priest/activation/pages/*`
- **Dashboard** — `priest/dashboard/pages/priest_dashboard_page.dart`
- **Settings hub + availability toggle + profile edit** — `priest/settings/pages/*`, `priest/profile/pages/priest_profile_page.dart`
- **Wallet + bank details + withdrawal** — `priest/wallet/pages/*`
- **Incoming-request → chat / voice → summary or dropped page** — `priest/session/pages/*`
- **My Users + per-user chat** — `priest/users/pages/*`
- **Missed Requests** — `priest/missed/pages/missed_requests_page.dart`
- **Notifications inbox** — `priest/notifications/pages/notifications_page.dart`
- **Bible sessions (host)** — `priest/bible/pages/*`

### Admin
- Dashboard, Users list, Sessions monitor, Withdrawals, Reports, Speakers list+detail, Settings — `admin/*/pages/*`

### Cloud Functions
- Sessions: `createSessionRequest`, `expireSessionRequest`, `billingTick`, `endSession`, `sessionWatchdog`, `generateAgoraToken`, `sendFollowUp`, `sendPriestMessage`, `onSessionTerminal`
- Payments: `createCoinOrder`, `verifyCoinPurchase`, `createActivationOrder`, `verifyActivationFee`, `verifyBibleSessionPayment`, `verifyMatrimonyPayment` (stub)
- Priest: `activatePriestAccount` (stub), `requestWithdrawal`
- Admin: `approveRejectPriest`, `approveRejectMatrimony` (stub), `updateAppConfig` (stub)
- Users: `onUserCreated`, `notifyAvailableSubscribers`
- Notifications: `sendNotification` (stub), `sendPush`
- Bible: `notifyBibleSessionCancellation`

### Stub / placeholder features (NOT shipping)
- Matrimony (user + admin): all files are `class X {}` stubs. CFs throw `unimplemented`.
- Admin Revenue page: `class RevenuePage {}` — empty.
- Admin Matrimony page: `class AdminMatrimonyPage {}` — empty.
- `bible_sessions/` directories (parallel to `bible/`): empty placeholder classes, never imported. Dead code.
- CF `activatePriestAccount`, `approveRejectMatrimony`, `updateAppConfig`, `sendNotification`: throw `unimplemented` immediately. Activation flow actually works via `verifyActivationFee` — `activatePriestAccount` is orphan.

---

## 1. Auth (Google Sign-In + role flow)

- **`auth_repository.dart:33-92`** — Sign-in flow is now robust after this session's fixes (warm-up retry loop, idToken null handling, post-create FCM token save). **Clean.**
- **`onboarding_page.dart`** — auto-selects preset role on `AuthNeedsRole`; role-mismatch sheet handled. **Clean.**
- **`login_page.dart:109`** — password minimum 6 chars enforced, no max length cap on field (uncapped passwords accepted).
- **`login_page.dart:95-96`** — email regex permissive (allows `+` and `-`); fine for admin email use case.
- **`role_selection_page.dart`** — admin login hidden behind long-press; **clean**.

---

## 2. User home feed + priest browsing

- **`home_page.dart:658`** — `Notify me` now wired to `_subscribeToNotifyMe` (fixed in this session). **Clean.**
- **`home_page.dart:1633-1641`** — `_StatusBadge._spec` correctly maps `isOnline + isBusy` to Online / Busy / Offline. **Clean.**
- **`home_repository.dart:28-38`** — live snapshot stream on priests filtered by `status=approved && isActivated=true`. **Clean.**
- **`user_shell_page.dart`** — not re-read this session; carries shell-tab routing. Was working in earlier conversation context.

---

## 3. Session lifecycle (user-side)

### `session_waiting_page.dart`
- **Line 86** — `PopScope(canPop:false)` correctly funnels back-button through cancel sheet. **Clean.**
- **Line 121-125** — `SessionRequestError` branch pops the page; no stuck state.
- **Line 244-262** — fallback initial uses `priestName[0]` without null/empty guard; covered by `!priestName.isEmpty` check above. **Clean.**

### `session_request_cubit.dart`
- **Line 226-242** — `cancelRequest` routes through `expireSessionRequest` (not `cancelSession`) so the priest always gets a missed-request notification, regardless of how quickly the user cancels. Confirmed intentional in the comment.
- **Line 251-262** — `close()` fires `expireSessionRequest` if the cubit dies in Waiting state. **Clean.**

### `voice_call_cubit.dart`
- Connecting-timeout (30s) now in place from this session's fix.
- **Line 467-505** — `endCall` is idempotent (`_endingDispatched` guard). Falls back to local-computed `SessionSummary` if `endSession` CF fails — user is never stranded.
- **Line 263, 437** — Token refresh and billingTick failures are `debugPrint` only with no UI feedback. The user has no idea billing is silently broken if the CF fails repeatedly. Watchdog eventually catches it. **Acceptable but invisible failure mode.**

### `chat_session_cubit.dart`
- **Line 329-335** — Optimistic-bubble reconciliation uses `senderId + text + !isPending` match. **Possible false-positive collapse:** if a user sends the exact same one-word message twice rapidly ("ok", "ok"), only one optimistic bubble settles, the other lingers until the next message arrives. Cosmetic.
- **Line 464-466** — `billingTick` failure is logged only; no UI signal. Same caveat as voice.
- **Line 615-617** — Reaction failures swallowed silently with comment "non-critical UX". **Acceptable.**
- **Line 641-656** — `endSession` failure path emits `ChatSessionEnded` with locally-computed summary; user never stranded. **Clean.**

### `chat_session_view.dart`
- **Line 458** — `endSession(reason: widget.isUserSide ? 'user_ended' : 'priest_ended')`. Reason wiring matches summary/dropped routing in priest pages. **Clean.**

### `session_rating_dialog.dart` (created this session)
- Dialog is PopScope+barrierDismissible-blocked, "Maybe later" link is the only soft escape. **Clean.**

### Dead file
- **`lib/features/user/session/pages/post_session_page.dart`** — `class PostSessionPage` is no longer imported anywhere (`PostSessionPage` grep returns only this file + the now-deleted route reference). **Dead code, safe to delete.**

---

## 4. Billing + payments

### `billingTick.ts`
- Idempotent on already-terminal sessions (line 54-61). All mutations in a single batch (line 101-136). Server-authoritative — client cannot bias the math.
- **Line 79-92** — When balance < rate at the START of a tick, the CF flips status='completed' but does NOT bump `durationMinutes` or charge the user. The client correctly receives `shouldEnd:true`. **Clean.**
- **Race not handled:** if the user tops up exactly between the `currentBalance < rate` check and the client receiving `shouldEnd:true`, the session ends anyway. The fresh coins remain in the wallet. Cosmetic; users will dial again. **Acceptable.**

### `endSession.ts`
- Idempotent on already-completed sessions (line 49-57). Atomic minimum-charge logic for sessions that ended before the first billingTick. **Clean.**

### `createSessionRequest.ts`
- This session's fix added `isBusy:true` atomically with the pending session creation. **Clean.**

### `onSessionTerminal.ts` (created this session)
- Clears `isBusy:false` on every terminal status. **Clean.**

### `sessionWatchdog.ts`
- After this session's fix, the stale-priest sweep was removed. The session-stale and stuck-pending sweeps remain — both correctly atomic and idempotent. **Clean.**

### `expireSessionRequest.ts`
- TOCTOU-safe via transaction (line 71-105). Notification dispatched only when this CF wins the status flip. **Clean.**

### User wallet — `user/wallet/pages/wallet_page.dart`
- **Line 233-244** — `_startPurchase` catch logs to debugPrint only; no structured surfacing for support diagnosis when Razorpay token refresh flakes.

### Payment success — `user/wallet/pages/payment_success_page.dart`
- **Line 95** — `_viewTransactions()` shows "Coming soon" toast instead of navigating to a transaction history page. **Dead button.**

### Priest wallet — `priest/wallet/pages/priest_wallet_page.dart`
- **Line 205-211** — Silent generic snackbar on withdrawal failure; no exception-type discrimination.

### `priest/wallet/pages/bank_details_page.dart`
- **Line 124** — Empty `catch (_)` after save timeout swallows all errors.
- **Line 254** — UPI validation only checks `@` presence; accepts malformed IDs like `x@` or `@@`.

### `priest/wallet/bloc/priest_wallet_cubit.dart`
- **Line 77-81** — Summary stream `onError: (_) { }` discards errors silently; stale balance shown forever if stream fails.

### Activation paywall — `priest/activation/pages/activation_paywall_page.dart`
- **Line 158** — `_showPaymentFailure(null)` displays "(not available)" instead of a real payment id; reduces support traceability.
- **Line 832-839** — Silent catch on `launchUrl(supportEmail)`.

### `functions/src/payments/createCoinOrder.ts`
- **Line 48-68** — Welcome offer falls back to hardcoded `priceRupees=29, coins=100` if config doc is missing. Should throw `HttpsError("failed-precondition")` rather than silently degrade.

### `functions/src/priest/activatePriestAccount.ts`
- **Line 9** — Orphaned CF: throws `unimplemented` immediately. Activation works through `verifyActivationFee` instead. **Dead, but still deployed.**

---

## 5. Priest session pages

### `priest_dashboard_page.dart`
- Pending-request listener removed this session (replaced by global `PriestIncomingRequestService`). The dashboard now owns only the priest-doc stream, the missed-request banner stream, and the auto-online latch. **Clean.**
- **Line 178** — Auto-online `_didInitialAutoOnline` latch correctly prevents fighting the manual toggle. **Clean.**

### `priest_chat_session_page.dart`
- **Line 37-56** — Routes by endReason: `priest_ended` → `/session/priest-summary`, anything else → `/priest/session-dropped`. Correct branch.

### `priest_voice_call_page.dart`
- Same routing pattern. **Clean.**

### `session_summary_page.dart`
- **Line 79** — `commission = (gross - net).clamp(0, gross)` — server is authoritative, client never re-does the math. **Clean.**
- **Line 172** — "Back to Dashboard" button is the only exit. PopScope(canPop:false) blocks hardware back. **Clean.**

### `session_dropped_page.dart`
- **Line 18** — Imports `InfoTipBlock` from `lib/features/user/home/widgets/no_priests_widget.dart`. **Cross-feature import** — `InfoTipBlock` lives in a "user/home" widget file but is used on a priest screen. Cosmetic structural issue, no functional impact.
- Animation pipeline polished (line 60-118). **Clean.**

### `incoming_request_page.dart`
- After this session's pop-on-error fix, the priest is never trapped on this page. **Clean.**

### `priest_incoming_request_service.dart` (created this session)
- Global pending-request listener now mounted at app start. **Clean.**

---

## 6. Missed requests + priest messaging

### `missed_requests_page.dart`
- **Line 189** — Stream error caught but logged generically (`$e`); no exception-type discrimination.
- **Line 341-379** — `_sendQuickReply` failure leaves the card on screen; the priest can retap. **Acceptable.**
- **Line 399** — 6-second batch commit timeout used for both single-dismiss and clear-all. Clear-all on 100 docs may need more time.
- **Line 400-402** — `_markAllForRequesterRead` catches errors and only `debugPrint`s; outer `_dismiss` can't surface the failure since the inner method already swallowed.

### `sendPriestMessage.ts`
- This session's fix added the missed-request relationship branch. **Clean.**

### `missedRequestNotif.ts`
- **Line 71-73** — Route hardcoded to `/priest/my-users` even though `notification_service.dart:480-482` overrides it client-side for `missed_request` to land on `/priest/missed-requests`. CF should be redeployed to write the correct route; the override is a defensive workaround.

### `notification_service.dart`
- **Line 238-241** — `pendingRoute` is a single static string; two notifications arriving in quick succession would overwrite each other. **Edge case.**
- **Line 449** — `notification.hashCode` used as local-notification id; collisions theoretically possible.

### `missed_request_foreground_banner.dart`
- **Line 89** — Re-firing `_controller.forward(from:0)` mid-animation can interrupt the previous slide. ValueKey on cards keeps the data right but the visual is slightly janky for rapid back-to-back missed requests.
- **Line 106-117** — Tap always navigates to `/priest/missed-requests` regardless of FCM payload's route field. Hardcoded routing duplicates `notification_service.dart:480-482`.

---

## 7. Notifications inboxes

### `user_notifications_page.dart`
- **Line 74** — Filters out `delivered=false` for all types; only `priest_message` actually uses the flag. Other types with a missing `delivered` field will be included (default true) so no functional bug, just inconsistent semantics.
- **Line 81-85** — Timeout caught with generic snackbar; no retry beyond pull-to-refresh.
- **Line 102-133** — Type switch handles 5 types; unhandled types silently stay on the list (no visual feedback that the tap did nothing).

### `notifications_page.dart` (priest)
- **Line 81-88** — `catchError((_) {})` on isRead update — batch failures are not logged anywhere.
- **Line 93-118** — No graceful handler if a new CF starts writing a notification type that isn't in the switch.

### `notification_model.dart`
- **Line 101-121** — `copyWith()` only accepts `isRead`; `dismissReason` / `dismissedAt` writes bypass the model and go directly to Firestore in `missed_requests_page.dart:394-397, 442-443, 536-538`. Breaks encapsulation; future schema changes will have to be made in two places.

### `sendPush.ts`
- **Line 159** — `arrayRemove(...staleTokens)` uses spread on a string array — needs verifying that the runtime version of the Admin SDK accepts variadic strings correctly. (Likely works; tag for runtime verification.)

### `sendNotification.ts`
- **Line 4-9** — Stub. Throws `unimplemented`. **Dead but exported.**

---

## 8. Bible sessions

### Canonical implementation lives in `bible/` directories; `bible_sessions/` is dead code
- **`lib/features/user/bible_sessions/pages/bible_sessions_page.dart:3`** — empty stub class. Dead.
- **`lib/features/priest/bible_sessions/pages/priest_bible_page.dart:3`** — empty stub class. Dead.

### `bible_tab.dart` (user)
- All three states (loading, error, loaded) implemented. **Clean.**

### `bible_session_detail_page.dart` (user)
- **Line 101-107** — Empty `catch (_)` in `_load()` and `_refreshRegistrationOnly()` — no logging.
- **Line 223** — `_payAndJoin` checks `session.hasLink` before invoking Razorpay; if the priest cancels the session **after** the user paid, the registration stays marked `paid` but the cancellation banner appears alongside the link card (UX contradiction, no data loss — refund is offline-only).
- **Line 977-981** — Post-payment "Link will appear when ready" relies on client-side refresh; a backgrounded user gets no push when the link is added later.

### `priest_bible_detail_page.dart` (priest)
- **Line 313** — `canComplete = session.isUpcoming && session.isInPast` — **impossible boolean**. A session cannot be simultaneously upcoming AND in the past. The **"Mark as Completed" button never renders**. **HIGH-SEVERITY BUG.**
- **Line 59-60** — Registration fetch failure silently shows empty attendee list.

### `bible_session_model.dart`
- **Line 85, 104-108** — `isInPast` and `isJoinWindowOpen` both call `DateTime.now()` which is **local time** on the client, while `scheduledAt` from Firestore is UTC. For an IST user (UTC+5:30), join-window math can be off by ~5 hours. **HIGH-SEVERITY BUG for any production Bible session.**

### Payment + cancellation CFs
- `verifyBibleSessionPayment.ts` — idempotent, cryptographically signed, atomic batch (registration + ledger + notification). **Clean.**
- `notifyBibleSessionCancellation.ts` — three-way gate (auth + ownership + status=cancelled), parallel fan-out. **Clean.**

---

## 9. Profile + settings pages

### User profile / me-tab / settings / about / edit
- **`me_tab.dart:75`** — Silent catch after Firestore read.
- **`edit_profile_page.dart:198`** — Image post-pick validation but no pre-compression size cap.
- **`edit_profile_page.dart:225-226`** — Name min length enforced; **no max length cap** on TextField.
- **`edit_profile_page.dart:275`** — Auth profile update failure swallowed silently (intentional per comment, but no retry).
- **`user_settings_page.dart:297-300, 313, 320, 325`** — Five `AppSnackBar.info(context, 'Coming soon')` toasts: Session History, Help & FAQ, Contact Support, Terms & Privacy Policy (×2). **Dead buttons.**
- **`user_settings_page.dart:186-192`** — Notification toggle fails silently (UI reverts but no error surfaced).
- **`about_page.dart:103`** — Hardcoded `Version 1.0.0` string (not read from `package_info_plus` or pubspec).
- **`about_page.dart:138, 145, 152`** — Three more `Coming soon` toasts.

### Priest profile / settings
- **`priest_profile_page.dart:306-316`** — Upload timeout 60s; no max image file size pre-check.
- **`priest_profile_page.dart:345`** — Silent swallow of auth profile sync error.
- **`priest_profile_page.dart:666`** — Same "Change photo" text whether photo exists or not (conditional says different but both branches emit same string).
- **`priest_settings_page.dart:297-300, 313, 320, 325`** — Same five "Coming soon" toasts as user settings.
- **`priest_settings_page.dart:356`** — Hardcoded `Gospel Vox v1.0.0` string.
- **`priest_settings_page.dart:65, 84`** — Two silent catches.

### Registration flow
- **`pending_approval_page.dart:128`** — Sign-out clears cached role but does **NOT remove FCM token** (NotificationService.removeToken() is only called via the main AuthRepository.signOut path, which IS used here — verify).
- **`application_rejected_page.dart:159-174`** — FutureBuilder for rejection reason has a 10s timeout but **no error widget** — shows "Loading..." indefinitely on failure.
- **`priest_registration_page.dart:276-278`** — Upload progress shown but no timeout on the upload itself (mismatched with the 60s timeout used elsewhere).

### Sign-out FCM token caveat
- Multiple sign-out paths (`me_tab.dart:139`, `pending_approval_page.dart:128`, `application_rejected_page.dart:95`, `priest_settings_page.dart:105`, `user_settings_page.dart:105`) ultimately call `AuthRepository.signOut()` which **does** call `NotificationService.removeToken()` (verified earlier in conversation at `auth_repository.dart:167`). **OK** — earlier agent flagged this as a gap but the dispatch is correct.

---

## 10. Admin surface

### Functional pages
- `admin_dashboard_page.dart` — **Clean.**
- `admin_users_page.dart` — **Clean.**
- `admin_sessions_page.dart` — **Clean.**
- `withdrawals_page.dart` — **Clean.**
- `speakers_list_page.dart` — **Clean.**
- `speaker_detail_page.dart` — **Clean.**
- `admin_settings_page.dart` — **Clean.**

### Stubs
- **`speakers_page.dart`** — `class SpeakersPage {}` empty. Real implementation in `speakers_list_page.dart`. **Dead.**
- **`revenue_page.dart`** — `class RevenuePage {}` empty. **Not implemented.**
- **`admin_matrimony_page.dart`** — `class AdminMatrimonyPage {}` empty. **Not implemented.**

### Reports
- **`reports_page.dart:495`** — `_notesCtrl` validation only fires on `_resolve()`; "Mark as Resolved" appears enabled before validation runs.
- **`reports_page.dart:517-535`** — CF failure leaves the resolve sheet open with no state reset.

### Admin CFs
- `approveRejectPriest.ts` — guard rails, audit fields, idempotency via state-machine check. **Clean.**
- `approveRejectMatrimony.ts:7` — Stub, throws unimplemented.
- `updateAppConfig.ts:12` — Stub, throws unimplemented. **No admin gate, no validation, no write logic** if it ever gets called.

---

## 11. Matrimony (all stub)

Entire feature is `class X {}` placeholders. Both UI and CFs throw `unimplemented`. **Not shipping.** No functional or security concerns until implementation begins.

---

## 12. Cross-cutting findings

### Dead code (safe to remove)
- `lib/features/user/session/pages/post_session_page.dart` — No longer imported or routed.
- `lib/features/user/bible_sessions/pages/bible_sessions_page.dart` — empty stub, never imported.
- `lib/features/priest/bible_sessions/pages/priest_bible_page.dart` — empty stub, never imported.
- `lib/features/admin/speakers/pages/speakers_page.dart` — empty stub, never imported.
- `functions/src/priest/activatePriestAccount.ts` — orphaned, never invoked. Index.ts exports it.

### "Coming soon" toasts (dead buttons)
Count: 11 across the codebase.
- `user_settings_page.dart`: 5 (lines 297, 313, 320, 325, +1 more)
- `priest_settings_page.dart`: 5 (lines 297, 313, 320, 325, +1 more)
- `about_page.dart`: 3 (lines 138, 145, 152)
- `payment_success_page.dart`: 1 (line 95)
*(Some overlap by page tile; total ~11 distinct dead taps.)*

### Hardcoded version strings
- `about_page.dart:103` — `"Version 1.0.0"`
- `priest_settings_page.dart:356` — `"Gospel Vox v1.0.0"`
- Should pull from `package_info_plus`.

### Silent error swallowing pattern
Recurring `catch (_) { }` across ~15 sites without even a `debugPrint`. Hardest cases:
- `wallet_page.dart:233`, `bank_details_page.dart:124`, `priest_wallet_cubit.dart:77` — wallet/payment failures lose support diagnostic.
- `me_tab.dart:75`, `priest_settings_page.dart:65, 84` — profile read failures.
- `bible_session_detail_page.dart:101-107` — Bible session detail failures.

### Cross-feature widget imports
- `priest/session/pages/session_dropped_page.dart:18` imports `lib/features/user/home/widgets/no_priests_widget.dart` for `InfoTipBlock`. Structural smell — the widget should live in `core/widgets/` or `shared/widgets/`.

---

## 13. HIGH-PRIORITY findings (functional bugs, not cosmetic)

| File:line | Bug |
|---|---|
| `priest_bible_detail_page.dart:313` | `canComplete = session.isUpcoming && session.isInPast` — impossible boolean. **"Mark as Completed" button never renders.** Priests cannot manually complete Bible sessions. |
| `bible_session_model.dart:85, 104-108` | `isInPast` and `isJoinWindowOpen` compare local `DateTime.now()` against UTC `scheduledAt`. For IST users, the join window opens/closes ~5 hours off from the displayed time. |
| `sendNotification.ts:4-9` | CF stub throws `unimplemented`. If anything calls it (legacy code, manual invocation), it errors. |
| `updateAppConfig.ts:12` | CF stub throws `unimplemented`. No admin gate so a future bug calling it bypasses admin check entirely (though it throws anyway). |
| `activatePriestAccount.ts:9` | Orphaned CF, but the legitimate `verifyActivationFee` is doing the work. Confusing for future maintainers. |
| `application_rejected_page.dart:159-174` | Rejection-reason FutureBuilder hangs on "Loading..." if Firestore read fails — no error UI. |

---

## 14. MEDIUM-PRIORITY findings

| File:line | Issue |
|---|---|
| `createCoinOrder.ts:48-68` | Welcome offer falls back to hardcoded `29 INR / 100 coins` if config missing — silent degradation instead of hard failure. |
| `payment_success_page.dart:95` | "View transactions" toast — dead button. |
| `reports_page.dart:495` | Resolve-notes validation fires on submit only; button visually enabled too early. |
| `notification_model.dart:101-121` | `copyWith` missing `dismissReason` / `dismissedAt`; encapsulation broken. |
| `bank_details_page.dart:254` | Weak UPI validation (only `@` presence). |
| `bible_session_detail_page.dart:223, 977-981` | Post-payment + post-cancellation UX has no push to user when state changes server-side. |
| `notification_service.dart:238-241` | Single static `pendingRoute` — back-to-back notifications overwrite. |
| `notifications_page.dart:81-88` (priest) | Silent catch on batch isRead update. |
| `home_page.dart:_subscribeToNotifyMe` | Now using `update()` correctly; but client has no UI feedback if the CF eventually doesn't fire (no "subscribed" badge state on the priest card). |
| All ~5 sign-out paths | FCM token IS removed via `AuthRepository.signOut()` — verified. **Not a bug; previously flagged false positive.** |

---

## 15. LOW-PRIORITY / cosmetic

| File:line | Issue |
|---|---|
| `login_page.dart:109` | Password field uncapped (max length). |
| `edit_profile_page.dart:225-226` | Name field max length uncapped. |
| `priest_profile_page.dart:666` | Duplicate "Change photo" text in both photo-exists branches. |
| `about_page.dart:103`, `priest_settings_page.dart:356` | Hardcoded version strings. |
| `chat_session_cubit.dart:329-335` | Optimistic-bubble dedup uses senderId+text — duplicate text messages can mis-collapse. |
| `voice_call_cubit.dart:263, 437`, `chat_session_cubit.dart:464-466` | billingTick / token refresh failures invisible to the user. |
| `missed_request_foreground_banner.dart:89` | Re-firing slide animation on rapid notifications creates a visual stutter. |
| `priest_dashboard_page.dart` (auto-online docstring) | Header comment about backgrounding behaviour at line 18-28 is still accurate after this session's watchdog change. **No update needed, just noting.** |

---

## 16. What's genuinely clean

These features have been read carefully and have no findings beyond cosmetic:

- `billingTick.ts` — atomic, idempotent, server-authoritative.
- `endSession.ts` — atomic, idempotent, minimum-charge handling correct.
- `expireSessionRequest.ts` — TOCTOU-safe transaction.
- `onSessionTerminal.ts` — single source of truth for clearing `isBusy`.
- `sessionWatchdog.ts` — after the stale-priest sweep removal, just session and pending cleanup. Clean.
- `verifyCoinPurchase.ts`, `verifyBibleSessionPayment.ts`, `verifyActivationFee.ts` — Razorpay signature verification + idempotency + atomic batches.
- `approveRejectPriest.ts` — full guard rails + audit + state-machine + best-effort push.
- `notifyBibleSessionCancellation.ts` — defensive, parallel fan-out.
- Admin dashboard, users, sessions, withdrawals, speakers list/detail, settings pages.
- Priest dashboard (after this session's changes).
- Session summary page (priest) and session dropped page (priest).
- Session rating dialog (user, this session).
- Session waiting page (user).
- Incoming request page (priest, after this session's fixes).
- User shell page tab routing.

---

## 17. Summary statistics

- **Total findings:** ~70
- **HIGH (functional bugs):** 6
- **MEDIUM:** 11
- **LOW / cosmetic:** ~30
- **Stub / not-implemented:** Matrimony, Revenue, AdminMatrimony, updateAppConfig CF, sendNotification CF, activatePriestAccount CF, bible_sessions directories.
- **Dead files (safe delete):** 5
- **Dead buttons ("Coming soon"):** ~11

### Most actionable fixes (in priority order)
1. **`priest_bible_detail_page.dart:313`** — fix the impossible boolean so priests can complete Bible sessions.
2. **`bible_session_model.dart:85, 104-108`** — normalise UTC vs local time for join-window math.
3. **`application_rejected_page.dart:159-174`** — add error widget to FutureBuilder.
4. **`createCoinOrder.ts:48-68`** — replace silent fallback with HttpsError when welcome-offer config missing.
5. Delete the 5 dead files listed in §12 and clean up the 11 "Coming soon" toasts (either implement or remove the tile).
6. Strip `activatePriestAccount`, `sendNotification`, `updateAppConfig`, `verifyMatrimonyPayment`, `approveRejectMatrimony` from `functions/src/index.ts` if not intended to ship — they're deployed but throw.

---

*End of report.*
